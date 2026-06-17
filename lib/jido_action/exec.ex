defmodule Jido.Exec do
  @moduledoc """
  Action execution engine with modular architecture for robust action processing.

  This module provides the core execution interface for Jido Actions with specialized
  helper modules handling specific concerns:

  - **Jido.Exec.Validator** - Parameter and output validation
  - **Jido.Exec.Telemetry** - Logging and telemetry events
  - **Jido.Exec.Retry** - Exponential backoff and retry logic
  - **Jido.Exec.Async** - Asynchronous execution management
  - **Jido.Exec.Closure** - Action closures with pre-applied context

  ## Core Features

  - Synchronous and asynchronous action execution
  - Automatic retries with exponential backoff
  - Timeout handling for long-running actions
  - Parameter and context normalization
  - Comprehensive error handling
  - Telemetry integration for monitoring and tracing
  - Action cancellation and cleanup

  ## Usage

  Basic action execution:

      Jido.Exec.run(MyAction, %{param1: "value"}, %{context_key: "context_value"})

  Asynchronous execution:

      async_ref = Jido.Exec.run_async(MyAction, params, context)
      # ... do other work ...
      result = Jido.Exec.await(async_ref)

  See `Jido.Action` for how to define an Action.
  """
  alias Jido.Action.Error
  alias Jido.Action.Util
  alias Jido.Exec.Async
  alias Jido.Exec.Propagation
  alias Jido.Exec.Retry
  alias Jido.Exec.Result
  alias Jido.Exec.Supervisors
  alias Jido.Exec.Telemetry
  alias Jido.Exec.Validator
  alias Jido.Flow
  alias Jido.Instruction
  alias Runic.Runner
  alias Runic.Workflow
  alias Runic.Workflow.PolicyDriver
  alias Runic.Workflow.Runnable
  alias Runic.Workflow.SchedulerPolicy

  require Logger

  @default_timeout 30_000
  @default_max_cycles 1_000
  @no_input :__jido_exec_no_input__
  @deadline_key :__jido_deadline_ms__
  @valid_error_normalization_modes [:legacy, :granular]
  @deprecated_error_normalization_key :error_normalization

  # Helper functions to get configuration values with fallbacks
  defp get_default_timeout,
    do: resolve_non_neg_integer_config(:default_timeout, @default_timeout)

  defp resolve_non_neg_integer_config(key, fallback) do
    case Application.get_env(:jido_action, key, fallback) do
      value when is_integer(value) and value >= 0 ->
        value

      invalid ->
        Logger.warning(fn ->
          "Invalid :jido_action config for #{inspect(key)}: #{inspect(invalid)}. " <>
            "Expected a non-negative integer; using fallback #{fallback}."
        end)

        fallback
    end
  end

  @type action :: module() | Instruction.t()
  @type executable :: action() | Flow.t() | Workflow.t()
  @type params :: map()
  @type context :: map()
  @type run_opts :: keyword()
  @type async_ref :: %{
          required(:ref) => reference(),
          required(:pid) => pid(),
          optional(:owner) => pid(),
          optional(:monitor_ref) => reference()
        }

  # Execution result types
  @type exec_success :: {:ok, map()}
  @type exec_success_dir :: {:ok, map(), any()}
  @type exec_error :: {:error, Exception.t()}
  @type exec_error_dir :: {:error, Exception.t(), any()}

  @type exec_result ::
          exec_success
          | exec_success_dir
          | exec_error
          | exec_error_dir

  @doc """
  Executes a Action synchronously with the given parameters and context.

  ## Parameters

  - `action`: The module implementing the Action behavior.
  - `params`: A map of input parameters for the Action.
  - `context`: A map providing additional context for the Action execution.
  - `opts`: Options controlling the execution:
    - `:timeout` - Maximum time (in ms) allowed for the Action to complete (configurable via `:jido_action, :default_timeout`).
    - `:max_retries` - Maximum number of retry attempts (configurable via `:jido_action, :default_max_retries`).
    - `:backoff` - Initial backoff time in milliseconds, doubles with each retry (configurable via `:jido_action, :default_backoff`).
    - `:log_level` - Override the Jido execution log threshold for this specific action. Accepts #{inspect(Logger.levels())}. Global Logger config still applies.
    - `:telemetry` - `:full` (default) or `:silent` for action span emission.
    - `:context_propagators` - Runtime context propagator modules captured before supervised execution and reattached inside supervised tasks.
    - `:context_propagator_failure_mode` - `:warn` (default) to skip failing propagators or `:strict` to raise when propagation callbacks fail.
    - `:error_normalization` - Deprecated compatibility shim. Accepted and ignored; canonical structured execution error normalization is always used.
    - `:jido` - Optional instance name for isolation. Routes execution through instance-scoped supervisors (e.g., `MyApp.Jido.TaskSupervisor`).

  ## Returns

  - `{:ok, result}` if the Action executes successfully.
  - `{:error, reason}` if an error occurs during execution.

  ## Examples

      iex> Jido.Exec.run(MyAction, %{input: "value"}, %{user_id: 123})
      {:ok, %{result: "processed value"}}

      iex> Jido.Exec.run(MyAction, %{invalid: "input"}, %{}, timeout: 1000)
      {:error, %Jido.Action.Error{type: :validation_error, message: "Invalid input"}}

      iex> Jido.Exec.run(MyAction, %{input: "value"}, %{}, log_level: :debug)
      {:ok, %{result: "processed value"}}

  """
  @spec run(executable(), params(), context() | run_opts(), run_opts()) ::
          exec_result() | {:ok, Result.t()} | {:error, Result.t()}
  def run(action, params \\ %{}, context \\ %{}, opts \\ [])

  def run(%Flow{} = flow, input, opts, []) when is_list(opts), do: run_flow(flow, input, opts)

  def run(%Flow{} = flow, input, context, []) when is_map(context) and map_size(context) == 0,
    do: run_flow(flow, input, [])

  def run(%Workflow{} = workflow, input, opts, []) when is_list(opts),
    do: run_flow(workflow, input, opts)

  def run(%Workflow{} = workflow, input, context, [])
      when is_map(context) and map_size(context) == 0,
      do: run_flow(workflow, input, [])

  def run(%Instruction{} = instruction, opts, context, [])
      when is_list(opts) and is_map(context) and map_size(context) == 0 do
    run(instruction, %{}, %{}, opts)
  end

  def run(%Instruction{} = instruction, params, context, opts) when is_list(opts) do
    with {:ok, instruction_params} <- normalize_params(instruction.params || %{}),
         {:ok, instruction_context} <- normalize_context(instruction.context || %{}),
         {:ok, instruction_opts} <- normalize_run_opts(instruction.opts || []),
         {:ok, normalized_params} <- normalize_params(params),
         {:ok, normalized_context} <- normalize_context(context),
         :ok <- Validator.validate_action(instruction.action) do
      run(
        instruction.action,
        Map.merge(instruction_params, normalized_params),
        Map.merge(instruction_context, normalized_context),
        Keyword.merge(instruction_opts, opts)
      )
    end
  end

  def run(action, params, context, opts) when is_atom(action) and is_list(opts) do
    opts = apply_compat_opts(opts)
    log_level = Util.resolve_log_level(opts)

    with {:ok, normalized_params} <- normalize_params(params),
         {:ok, normalized_context} <- normalize_context(context),
         :ok <- Validator.validate_action(action),
         {:ok, validated_params} <- Validator.validate_params(action, normalized_params) do
      do_run_with_retry(action, validated_params, normalized_context, opts)
    else
      {:error, reason} ->
        Telemetry.cond_log_failure(log_level, reason)
        {:error, reason}
    end
  rescue
    e in [FunctionClauseError, BadArityError, BadFunctionError] ->
      log_level = Util.resolve_log_level(opts)
      Telemetry.cond_log_function_error(log_level, e)

      {:error,
       Error.validation_error("Invalid action module: #{Telemetry.extract_safe_error_message(e)}")}

    e ->
      log_level = Util.resolve_log_level(opts)
      Telemetry.cond_log_unexpected_error(log_level, e)

      {:error,
       Error.internal_error(
         "An unexpected error occurred: #{Telemetry.extract_safe_error_message(e)}"
       )}
  catch
    kind, reason ->
      log_level = Util.resolve_log_level(opts)
      Telemetry.cond_log_caught_error(log_level, reason)

      {:error,
       Error.internal_error("Caught #{kind}: #{Telemetry.extract_safe_error_message(reason)}")}
  end

  def run(action, _params, _context, _opts) do
    {:error, Error.validation_error("Expected action to be a module, got: #{inspect(action)}")}
  end

  @doc """
  Executes a Action asynchronously with the given parameters and context.

  This function immediately returns a reference that can be used to await the result
  or cancel the action.

  **Note**: This approach integrates with OTP by spawning tasks under a `Task.Supervisor`.
  Make sure `{Task.Supervisor, name: Jido.Action.TaskSupervisor}` is part of your supervision tree.

  ## Parameters

  - `action`: The module implementing the Action behavior.
  - `params`: A map of input parameters for the Action.
  - `context`: A map providing additional context for the Action execution.
  - `opts`: Options controlling the execution (same as `run/4`).

  ## Returns

  An `async_ref` map containing:
  - `:ref` - A unique reference for this async action.
  - `:pid` - The PID of the process executing the Action.
  - `:owner` - The PID of the caller that started the async action.

  ## Examples

      iex> async_ref = Jido.Exec.run_async(MyAction, %{input: "value"}, %{user_id: 123})
      %{ref: #Reference<0.1234.5678>, pid: #PID<0.234.0>}

      iex> result = Jido.Exec.await(async_ref)
      {:ok, %{result: "processed value"}}
  """
  @spec run_async(action(), params(), context(), run_opts()) :: async_ref()
  def run_async(action, params \\ %{}, context \\ %{}, opts \\ []) do
    Async.start(action, params, context, opts)
  end

  @doc """
  Waits for the result of an asynchronous Action execution.

  ## Parameters

  - `async_ref`: The reference returned by `run_async/4`.
  - `timeout`: Maximum time (in ms) to wait for the result (default: 5000).

  ## Returns

  - `{:ok, result}` if the Action executes successfully.
  - `{:error, reason}` if an error occurs during execution or if the action times out.
  - `{:error, %Jido.Action.Error.InvalidInputError{}}` when awaited by a non-owner process.

  ## Examples

      iex> async_ref = Jido.Exec.run_async(MyAction, %{input: "value"})
      iex> Jido.Exec.await(async_ref, 10_000)
      {:ok, %{result: "processed value"}}

      iex> async_ref = Jido.Exec.run_async(SlowAction, %{input: "value"})
      iex> Jido.Exec.await(async_ref, 100)
      {:error, %Jido.Action.Error{type: :timeout, message: "Async action timed out after 100ms"}}
  """
  @spec await(async_ref()) :: exec_result
  def await(async_ref), do: Async.await(async_ref)

  @doc """
  Awaits the completion of an asynchronous Action with a custom timeout.

  ## Parameters

  - `async_ref`: The async reference returned by `run_async/4`.
  - `timeout`: Maximum time to wait in milliseconds.

  ## Returns

  - `{:ok, result}` if the Action completes successfully.
  - `{:error, reason}` if an error occurs or timeout is reached.
  """
  @spec await(async_ref(), timeout()) :: exec_result
  def await(async_ref, timeout), do: Async.await(async_ref, timeout)

  @doc """
  Cancels a running asynchronous Action execution.

  ## Parameters

  - `async_ref`: The reference returned by `run_async/4`, or just the PID of the process to cancel.

  ## Returns

  - `:ok` if the cancellation was successful.
  - `{:error, reason}` if the cancellation failed or the input was invalid.
  - `{:error, %Jido.Action.Error.InvalidInputError{}}` when cancelled by a non-owner process.

  ## Examples

      iex> async_ref = Jido.Exec.run_async(LongRunningAction, %{input: "value"})
      iex> Jido.Exec.cancel(async_ref)
      :ok

      iex> Jido.Exec.cancel("invalid")
      {:error, %Jido.Action.Error{type: :invalid_async_ref, message: "Invalid async ref for cancellation"}}
  """
  @spec cancel(async_ref() | pid()) :: :ok | exec_error
  def cancel(async_ref_or_pid), do: Async.cancel(async_ref_or_pid)

  @doc false
  @spec invoke_action_once(action(), params(), context(), run_opts()) :: exec_result()
  def invoke_action_once(action, params \\ %{}, context \\ %{}, opts \\ [])

  def invoke_action_once(%Instruction{} = instruction, params, context, opts)
      when is_list(opts) do
    with {:ok, instruction_params} <- normalize_params(instruction.params || %{}),
         {:ok, instruction_context} <- normalize_context(instruction.context || %{}),
         {:ok, instruction_opts} <- normalize_run_opts(instruction.opts || []),
         {:ok, normalized_params} <- normalize_params(params),
         {:ok, normalized_context} <- normalize_context(context),
         :ok <- Validator.validate_action(instruction.action) do
      invoke_action_once(
        instruction.action,
        Map.merge(instruction_params, normalized_params),
        Map.merge(instruction_context, normalized_context),
        Keyword.merge(instruction_opts, opts)
      )
    end
  end

  def invoke_action_once(action, params, context, opts) when is_atom(action) and is_list(opts) do
    opts = apply_compat_opts(opts)
    log_level = Util.resolve_log_level(opts)

    with {:ok, normalized_params} <- normalize_params(params),
         {:ok, normalized_context} <- normalize_context(context),
         :ok <- Validator.validate_action(action),
         {:ok, validated_params} <- Validator.validate_params(action, normalized_params) do
      do_invoke_action_once(action, validated_params, normalized_context, opts)
    else
      {:error, reason} ->
        Telemetry.cond_log_failure(log_level, reason)
        {:error, reason}
    end
  rescue
    e in [FunctionClauseError, BadArityError, BadFunctionError] ->
      log_level = Util.resolve_log_level(opts)
      Telemetry.cond_log_function_error(log_level, e)

      {:error,
       Error.validation_error("Invalid action module: #{Telemetry.extract_safe_error_message(e)}")}

    e ->
      log_level = Util.resolve_log_level(opts)
      Telemetry.cond_log_unexpected_error(log_level, e)

      {:error,
       Error.internal_error(
         "An unexpected error occurred: #{Telemetry.extract_safe_error_message(e)}"
       )}
  catch
    kind, reason ->
      log_level = Util.resolve_log_level(opts)
      Telemetry.cond_log_caught_error(log_level, reason)

      {:error,
       Error.internal_error("Caught #{kind}: #{Telemetry.extract_safe_error_message(reason)}")}
  end

  def invoke_action_once(action, _params, _context, _opts) do
    {:error, Error.validation_error("Expected action to be a module, got: #{inspect(action)}")}
  end

  @doc """
  Performs one Runic prepare/dispatch/apply cycle.

  If `input` is supplied it is planned into the workflow before dispatch. When
  the workflow has no runnable work, the returned result has status `:ok`.
  """
  @spec step(Flow.t() | Workflow.t(), term(), keyword()) ::
          {:ok, Result.t()} | {:error, Result.t()}
  def step(flow_or_workflow, input \\ @no_input, opts \\ [])

  def step(flow_or_workflow, opts, []) when is_list(opts) do
    step(flow_or_workflow, @no_input, opts)
  end

  def step(flow_or_workflow, input, opts) when is_list(opts) do
    with {:ok, workflow} <- normalize_workflow(flow_or_workflow) do
      workflow
      |> configure_workflow(opts)
      |> maybe_plan_input(input)
      |> do_step(opts, 1)
    end
  end

  @doc """
  Continues an existing workflow with new input and runs it to quiescence.
  """
  @spec resume(Flow.t() | Workflow.t(), term(), keyword()) ::
          {:ok, Result.t()} | {:error, Result.t()}
  def resume(flow_or_workflow, input), do: resume(flow_or_workflow, input, [])

  def resume(runner, flow_id, input) when is_atom(runner) do
    resume(runner, flow_id, input, [])
  end

  def resume(flow_or_workflow, input, opts) when is_list(opts) do
    run_flow(flow_or_workflow, input, opts)
  end

  @doc """
  Returns runtime results from a `Jido.Exec.Result`, `Jido.Flow`, or raw
  `Runic.Workflow`.
  """
  @spec results(Result.t() | Flow.t() | Workflow.t(), keyword()) :: term()
  def results(result_or_workflow), do: results(result_or_workflow, [])

  def results(runner, flow_id) when is_atom(runner), do: results(runner, flow_id, [])

  def results(%Result{results: results}, []), do: results
  def results(%Result{workflow: workflow}, opts), do: results(workflow, opts)

  def results(flow_or_workflow, opts) when is_list(opts) do
    workflow = Flow.to_workflow(flow_or_workflow)
    components = Keyword.get(opts, :components)

    cond do
      Keyword.get(opts, :raw, false) ->
        Workflow.raw_productions(workflow)

      is_list(components) ->
        Workflow.results(workflow, components, opts)

      true ->
        Workflow.results(workflow, nil, opts)
    end
  end

  @doc """
  Returns durable and in-memory events associated with a result or workflow.
  """
  @spec events(Result.t() | Flow.t() | Workflow.t(), keyword()) :: [term()]
  def events(result_or_workflow, opts \\ [])
  def events(%Result{events: events}, []), do: events
  def events(%Result{workflow: workflow}, opts), do: events(workflow, opts)

  def events(flow_or_workflow, _opts) do
    flow_or_workflow
    |> Flow.to_workflow()
    |> Workflow.event_log()
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  @doc """
  Returns a compact execution summary for a result, flow, or workflow.
  """
  @spec summary(Result.t() | Flow.t() | Workflow.t()) :: map()
  def summary(%Result{workflow: workflow, status: status, cycles: cycles, error: error}) do
    workflow
    |> summary()
    |> Map.merge(%{status: status, cycles: cycles, error: error})
  end

  def summary(flow_or_workflow) do
    workflow = Flow.to_workflow(flow_or_workflow)

    %{
      total_nodes: workflow |> Workflow.components() |> map_size(),
      facts_produced: workflow |> Workflow.facts() |> length(),
      satisfied?: not Workflow.is_runnable?(workflow),
      productions: workflow |> Workflow.raw_productions() |> length()
    }
  end

  @doc """
  Walks a produced fact's ancestry through the workflow.
  """
  @spec provenance(Result.t() | Flow.t() | Workflow.t(), term()) ::
          {:ok, [Runic.Workflow.Fact.t()]} | {:error, :not_found}
  def provenance(%Result{workflow: workflow}, fact_hash), do: provenance(workflow, fact_hash)

  def provenance(flow_or_workflow, fact_hash) do
    facts =
      flow_or_workflow
      |> Flow.to_workflow()
      |> Workflow.facts()
      |> Map.new(&{&1.hash, &1})

    case Map.fetch(facts, fact_hash) do
      {:ok, fact} -> {:ok, build_provenance_chain(fact, facts, [])}
      :error -> {:error, :not_found}
    end
  end

  @doc """
  Starts a flow under a managed Runic runner.
  """
  @spec start_flow(atom(), term(), Flow.t() | Workflow.t(), keyword()) ::
          DynamicSupervisor.on_start_child()
  def start_flow(runner, flow_id, flow_or_workflow, opts \\ []) when is_list(opts) do
    workflow =
      flow_or_workflow
      |> Flow.to_workflow()
      |> configure_workflow(opts)

    Runner.start_workflow(runner, flow_id, workflow, opts)
  end

  @doc """
  Feeds input to a managed flow.
  """
  @spec resume(atom(), term(), term(), keyword()) :: :ok | {:error, term()}
  def resume(runner, flow_id, input, opts) when is_list(opts) do
    Runner.run(runner, flow_id, input, opts)
  end

  @doc """
  Returns managed flow results.
  """
  @spec results(atom(), term(), keyword()) :: {:ok, term()} | {:error, term()}
  def results(runner, flow_id, opts) when is_atom(runner) and is_list(opts) do
    if opts == [] do
      Runner.get_results(runner, flow_id)
    else
      Runner.get_results(runner, flow_id, opts)
    end
  end

  @doc """
  Returns a managed Runic workflow.
  """
  @spec workflow(atom(), term()) :: {:ok, Workflow.t()} | {:error, term()}
  def workflow(runner, flow_id), do: Runner.get_workflow(runner, flow_id)

  @doc """
  Persists the current managed flow state when the runner store supports it.
  """
  @spec checkpoint(atom(), term()) :: :ok | {:error, term()}
  def checkpoint(runner, flow_id), do: Runner.checkpoint(runner, flow_id)

  @doc """
  Stops a managed flow.
  """
  @spec stop(atom(), term(), keyword()) :: :ok | {:error, term()}
  def stop(runner, flow_id, opts \\ []) when is_list(opts), do: Runner.stop(runner, flow_id, opts)

  # Internal execution helpers.
  @spec run_flow(Flow.t() | Workflow.t(), term(), keyword()) ::
          {:ok, Result.t()} | {:error, Result.t()}
  defp run_flow(flow_or_workflow, input, opts) when is_list(opts) do
    max_cycles = Keyword.get(opts, :max_cycles, @default_max_cycles)

    with {:ok, workflow} <- normalize_workflow(flow_or_workflow),
         :ok <- validate_max_cycles(max_cycles) do
      workflow
      |> configure_workflow(opts)
      |> maybe_plan_input(input)
      |> run_until_idle(0, max_cycles, opts)
    end
  end

  @spec do_step(Workflow.t(), keyword(), non_neg_integer()) ::
          {:ok, Result.t()} | {:error, Result.t()}
  defp do_step(%Workflow{} = workflow, opts, cycles) do
    if Workflow.is_runnable?(workflow) do
      {prepared_workflow, runnables} = Workflow.prepare_for_dispatch(workflow)
      {executed, events} = execute_runnables(runnables, prepared_workflow, opts)
      workflow = apply_runnables(prepared_workflow, executed)

      case Enum.find(executed, &match?(%Runnable{status: :failed}, &1)) do
        nil ->
          {:ok, Result.new(workflow, :ok, cycles: cycles, events: events(workflow) ++ events)}

        %Runnable{} = runnable ->
          error = failed_runnable_error(runnable)
          {:error, Result.new(workflow, :error, cycles: cycles, error: error, events: events)}
      end
    else
      {:ok, Result.new(workflow, :ok, cycles: 0)}
    end
  end

  defp run_until_idle(%Workflow{} = workflow, cycles, max_cycles, opts) do
    cond do
      not Workflow.is_runnable?(workflow) ->
        {:ok, Result.new(workflow, :ok, cycles: cycles)}

      cycles >= max_cycles ->
        error =
          Error.execution_error("flow exceeded max dispatch cycles", %{
            max_cycles: max_cycles,
            cycles: cycles
          })

        {:error, Result.new(workflow, :max_cycles, cycles: cycles, error: error)}

      true ->
        case do_step(workflow, opts, cycles + 1) do
          {:ok, %Result{workflow: workflow}} ->
            run_until_idle(workflow, cycles + 1, max_cycles, opts)

          {:error, %Result{} = result} ->
            {:error, result}
        end
    end
  end

  defp execute_runnables(runnables, workflow, opts) do
    runnables
    |> Enum.map(fn runnable ->
      execute_runnable(runnable, workflow, opts)
    end)
    |> Enum.map(fn
      {%Runnable{} = runnable, events} -> {runnable, events}
      %Runnable{} = runnable -> {runnable, []}
    end)
    |> Enum.unzip()
  end

  defp execute_runnable(%Runnable{} = runnable, %Workflow{} = workflow, opts) do
    policy = resolve_scheduler_policy(runnable, workflow, opts)
    policy_opts = policy_driver_opts(policy, opts)

    result =
      try do
        PolicyDriver.execute(runnable, policy, policy_opts)
      rescue
        exception ->
          Runnable.fail(runnable, format_runnable_exception(runnable, exception, __STACKTRACE__))
      catch
        kind, reason ->
          Runnable.fail(runnable, format_runnable_catch(runnable, kind, reason))
      end

    case result do
      {%Runnable{} = runnable, _events} = evented_result ->
        emit_runnable_telemetry(runnable)
        evented_result

      %Runnable{} = runnable ->
        emit_runnable_telemetry(runnable)
        runnable
    end
  end

  defp apply_runnables(%Workflow{} = workflow, runnables) do
    Enum.reduce(runnables, workflow, fn %Runnable{} = runnable, acc ->
      Workflow.apply_runnable(acc, runnable)
    end)
  end

  defp normalize_workflow(%Flow{} = flow), do: {:ok, Flow.to_workflow(flow)}
  defp normalize_workflow(%Workflow{} = workflow), do: {:ok, workflow}

  defp normalize_workflow(other) do
    {:error,
     Error.validation_error("expected a Jido.Flow or Runic.Workflow", %{
       value: other
     })}
  end

  defp validate_max_cycles(max_cycles) when is_integer(max_cycles) and max_cycles > 0, do: :ok

  defp validate_max_cycles(max_cycles) do
    {:error,
     Error.validation_error(":max_cycles must be a positive integer", %{
       max_cycles: max_cycles
     })}
  end

  defp configure_workflow(%Workflow{} = workflow, opts) do
    workflow
    |> maybe_put_run_context(Keyword.get(opts, :run_context))
    |> maybe_merge_scheduler_policies(opts)
  end

  defp maybe_plan_input(%Workflow{} = workflow, @no_input), do: workflow
  defp maybe_plan_input(%Workflow{} = workflow, input), do: Workflow.plan_eagerly(workflow, input)

  defp maybe_put_run_context(%Workflow{} = workflow, nil), do: workflow

  defp maybe_put_run_context(%Workflow{} = workflow, context) when is_map(context) do
    Workflow.put_run_context(workflow, context)
  end

  defp maybe_put_run_context(%Workflow{} = workflow, _context), do: workflow

  defp maybe_merge_scheduler_policies(%Workflow{} = workflow, opts) do
    runtime_policies = Keyword.get(opts, :scheduler_policies, [])
    base_policies = workflow.scheduler_policies || []
    policies = SchedulerPolicy.merge_policies(runtime_policies, base_policies)

    Workflow.set_scheduler_policies(workflow, policies)
  end

  defp resolve_scheduler_policy(%Runnable{} = runnable, %Workflow{} = workflow, opts) do
    policy_opts =
      %{}
      |> Map.merge(Map.new(app_policy_opts()))
      |> Map.merge(Map.new(node_policy_opts(runnable)))
      |> Map.merge(Map.new(matched_workflow_policy_opts(runnable, workflow.scheduler_policies)))
      |> Map.merge(Map.new(policy_opts_from_exec_opts(opts)))

    SchedulerPolicy.new(policy_opts)
  end

  defp policy_driver_opts(%SchedulerPolicy{execution_mode: :durable}, opts),
    do: Keyword.put(opts, :emit_events, true)

  defp policy_driver_opts(_policy, opts), do: opts

  defp app_policy_opts do
    []
    |> maybe_put_policy(:timeout_ms, config_timeout_ms())
    |> maybe_put_policy(:max_retries, config_non_neg_integer(:default_max_retries))
    |> maybe_put_policy(:base_delay_ms, config_non_neg_integer(:default_backoff))
    |> maybe_default_backoff()
  end

  defp node_policy_opts(%Runnable{node: %{exec_opts: exec_opts}}) when is_list(exec_opts) do
    policy_opts_from_exec_opts(exec_opts)
  end

  defp node_policy_opts(_runnable), do: []

  defp policy_opts_from_exec_opts(opts) when is_list(opts) do
    []
    |> maybe_put_policy(:timeout_ms, exec_timeout_ms(opts))
    |> maybe_put_policy(:max_retries, Keyword.get(opts, :max_retries))
    |> maybe_put_policy(:backoff, exec_backoff_strategy(opts))
    |> maybe_put_policy(:base_delay_ms, exec_base_delay_ms(opts))
    |> maybe_put_policy(:max_delay_ms, Keyword.get(opts, :max_delay_ms))
    |> maybe_put_policy(:on_failure, Keyword.get(opts, :on_failure))
    |> maybe_put_policy(:fallback, Keyword.get(opts, :fallback))
    |> maybe_put_policy(:execution_mode, Keyword.get(opts, :execution_mode))
    |> maybe_put_policy(:priority, Keyword.get(opts, :priority))
    |> maybe_put_policy(:executor, Keyword.get(opts, :executor))
    |> maybe_put_policy(:executor_opts, Keyword.get(opts, :executor_opts))
  end

  defp maybe_put_policy(opts, _key, nil), do: opts
  defp maybe_put_policy(opts, _key, :unset), do: opts
  defp maybe_put_policy(opts, key, value), do: Keyword.put(opts, key, value)

  defp matched_workflow_policy_opts(_runnable, []), do: []

  defp matched_workflow_policy_opts(%Runnable{node: node}, policies) when is_list(policies) do
    case Enum.find(policies, fn {matcher, _policy_map} -> policy_matches?(matcher, node) end) do
      {_matcher, policy_map} -> policy_map
      nil -> []
    end
  end

  defp policy_matches?(:default, _node), do: true

  defp policy_matches?(name, %{name: name}) when is_atom(name) or is_binary(name), do: true
  defp policy_matches?(name, _node) when is_atom(name) or is_binary(name), do: false

  defp policy_matches?({:name, %Regex{} = regex}, %{name: name}) when is_binary(name),
    do: Regex.match?(regex, name)

  defp policy_matches?({:name, %Regex{} = regex}, %{name: name}) when is_atom(name),
    do: Regex.match?(regex, Atom.to_string(name))

  defp policy_matches?({:name, %Regex{}}, _node), do: false

  defp policy_matches?({:type, module}, node) when is_atom(module),
    do: match?(%{__struct__: ^module}, node)

  defp policy_matches?({:type, modules}, %{__struct__: struct}) when is_list(modules),
    do: struct in modules

  defp policy_matches?(fun, node) when is_function(fun, 1) do
    fun.(node)
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp policy_matches?(_matcher, _node), do: false

  defp maybe_default_backoff(opts) do
    if Keyword.has_key?(opts, :base_delay_ms) and not Keyword.has_key?(opts, :backoff) do
      Keyword.put(opts, :backoff, :exponential)
    else
      opts
    end
  end

  defp config_timeout_ms do
    case Application.fetch_env(:jido_action, :default_timeout) do
      {:ok, 0} -> :infinity
      {:ok, value} when is_integer(value) and value > 0 -> value
      _ -> nil
    end
  end

  defp config_non_neg_integer(key) do
    case Application.fetch_env(:jido_action, key) do
      {:ok, value} when is_integer(value) and value >= 0 -> value
      _ -> nil
    end
  end

  defp exec_timeout_ms(opts) do
    cond do
      Keyword.has_key?(opts, :timeout_ms) ->
        Keyword.get(opts, :timeout_ms)

      Keyword.has_key?(opts, :timeout) ->
        case Keyword.get(opts, :timeout) do
          0 -> :infinity
          value -> value
        end

      true ->
        nil
    end
  end

  defp exec_backoff_strategy(opts) do
    case Keyword.get(opts, :backoff) do
      value when value in [:none, :linear, :exponential, :jitter] -> value
      value when is_integer(value) and value > 0 -> :exponential
      0 -> :none
      _ -> nil
    end
  end

  defp exec_base_delay_ms(opts) do
    case Keyword.get(opts, :backoff) do
      value when is_integer(value) and value >= 0 -> value
      _ -> Keyword.get(opts, :base_delay_ms)
    end
  end

  defp failed_runnable_error(%Runnable{} = runnable) do
    Error.execution_error("flow runnable failed", %{
      runnable_id: runnable.id,
      node: runnable_node_name(runnable),
      reason: runnable.error
    })
  end

  defp runnable_node_name(%Runnable{node: %{name: name}}) when not is_nil(name), do: name
  defp runnable_node_name(%Runnable{node: %{hash: hash}}) when not is_nil(hash), do: hash
  defp runnable_node_name(%Runnable{node: node}), do: inspect(node)

  defp format_runnable_exception(%Runnable{} = runnable, exception, stacktrace) do
    %{
      node: runnable_node_name(runnable),
      exception: exception,
      message: Exception.format(:error, exception, stacktrace)
    }
  end

  defp format_runnable_catch(%Runnable{} = runnable, kind, reason) do
    %{
      node: runnable_node_name(runnable),
      kind: kind,
      reason: reason,
      message: "caught #{kind}: #{inspect(reason)}"
    }
  end

  defp emit_runnable_telemetry(%Runnable{} = runnable) do
    :telemetry.execute(
      [:jido, :flow, :runnable, runnable.status],
      %{system_time: System.system_time()},
      %{node: runnable.node, runnable_id: runnable.id}
    )
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp build_provenance_chain(
         %Runic.Workflow.Fact{ancestry: {_producer_hash, parent_hash}} = fact,
         facts,
         acc
       ) do
    case Map.fetch(facts, parent_hash) do
      {:ok, parent} -> build_provenance_chain(parent, facts, [fact | acc])
      :error -> [fact | acc]
    end
  end

  defp build_provenance_chain(%Runic.Workflow.Fact{} = fact, _facts, acc), do: [fact | acc]

  @spec normalize_params(params()) :: {:ok, map()} | {:error, Exception.t()}
  defp normalize_params(%_{} = error) when is_exception(error), do: {:error, error}
  defp normalize_params(params) when is_map(params), do: {:ok, params}
  defp normalize_params(params) when is_list(params), do: {:ok, Map.new(params)}
  defp normalize_params({:ok, params}) when is_map(params), do: {:ok, params}
  defp normalize_params({:ok, params}) when is_list(params), do: {:ok, Map.new(params)}
  defp normalize_params({:error, reason}), do: {:error, Error.validation_error(reason)}

  defp normalize_params(params),
    do:
      {:error,
       Error.validation_error(
         "Invalid params type: #{Telemetry.extract_safe_error_message(params)}"
       )}

  @spec normalize_context(context()) :: {:ok, map()} | {:error, Exception.t()}
  defp normalize_context(context) when is_map(context), do: {:ok, context}
  defp normalize_context(context) when is_list(context), do: {:ok, Map.new(context)}

  defp normalize_context(context),
    do:
      {:error,
       Error.validation_error(
         "Invalid context type: #{Telemetry.extract_safe_error_message(context)}"
       )}

  defp normalize_run_opts(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      {:ok, opts}
    else
      {:error,
       Error.validation_error("Invalid opts type: #{Telemetry.extract_safe_error_message(opts)}")}
    end
  end

  defp normalize_run_opts(opts) do
    {:error,
     Error.validation_error("Invalid opts type: #{Telemetry.extract_safe_error_message(opts)}")}
  end

  @spec do_run_with_retry(action(), params(), context(), run_opts()) :: exec_result
  defp do_run_with_retry(action, params, context, opts) do
    retry_opts = Retry.extract_retry_opts(opts)
    max_retries = retry_opts[:max_retries]
    backoff = retry_opts[:backoff]
    do_run_with_retry(action, params, context, opts, 0, max_retries, backoff)
  end

  @spec do_run_with_retry(
          action(),
          params(),
          context(),
          run_opts(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: exec_result
  defp do_run_with_retry(action, params, context, opts, retry_count, max_retries, backoff) do
    case do_run(action, params, context, opts) do
      {:ok, result} ->
        {:ok, result}

      {:ok, result, other} ->
        {:ok, result, other}

      {:error, reason, other} ->
        maybe_retry(
          action,
          params,
          context,
          opts,
          retry_count,
          max_retries,
          backoff,
          {:error, reason, other}
        )

      {:error, reason} ->
        maybe_retry(
          action,
          params,
          context,
          opts,
          retry_count,
          max_retries,
          backoff,
          {:error, reason}
        )
    end
  end

  defp maybe_retry(
         action,
         params,
         context,
         opts,
         retry_count,
         max_retries,
         initial_backoff,
         error
       ) do
    if Retry.should_retry?(error, retry_count, max_retries, opts) do
      Retry.execute_retry(action, retry_count, max_retries, initial_backoff, opts, fn ->
        do_run_with_retry(
          action,
          params,
          context,
          opts,
          retry_count + 1,
          max_retries,
          initial_backoff
        )
      end)
    else
      error
    end
  end

  @spec do_invoke_action_once(action(), params(), context(), run_opts()) :: exec_result
  defp do_invoke_action_once(action, params, context, opts) do
    telemetry = resolve_telemetry_mode(opts)

    invoke = fn -> execute_action(action, params, context, opts) end

    case telemetry do
      :silent ->
        invoke.()

      :full ->
        :telemetry.span(
          [:jido, :action],
          Telemetry.span_start_metadata(action, params, context, opts),
          fn ->
            result = invoke.()
            {result, Telemetry.span_stop_metadata(action, params, context, result, opts)}
          end
        )
    end
  end

  @spec do_run(action(), params(), context(), run_opts()) :: exec_result
  defp do_run(action, params, context, opts) do
    telemetry = resolve_telemetry_mode(opts)

    with {:ok, timeout, budgeted_context} <- resolve_timeout_budget(context, opts) do
      execute_with_timeout = fn ->
        execute_action_with_timeout(action, params, budgeted_context, timeout, opts)
      end

      result =
        case telemetry do
          :silent ->
            execute_with_timeout.()

          :full ->
            :telemetry.span(
              [:jido, :action],
              Telemetry.span_start_metadata(action, params, budgeted_context, opts),
              fn ->
                result = execute_with_timeout.()

                {result,
                 Telemetry.span_stop_metadata(action, params, budgeted_context, result, opts)}
              end
            )
        end

      case result do
        {:ok, _result} = success ->
          success

        {:ok, _result, _other} = success ->
          success

        {:error, %Jido.Action.Error.TimeoutError{}} = timeout_err ->
          timeout_err

        {:error, _error, _other} = error ->
          error

        {:error, _error} = error ->
          error
      end
    end
  end

  @spec execute_action_with_timeout(
          action(),
          params(),
          context(),
          non_neg_integer(),
          run_opts()
        ) :: exec_result
  defp execute_action_with_timeout(action, params, context, timeout, opts)

  defp execute_action_with_timeout(action, params, context, 0, opts) do
    execute_action(action, params, context, opts)
  end

  @dialyzer {:nowarn_function, execute_action_with_timeout: 5}
  defp execute_action_with_timeout(action, params, context, timeout, opts)
       when is_integer(timeout) and timeout > 0 do
    # Get the current process's group leader for IO routing
    current_gl = Process.group_leader()

    # Resolve supervisor based on jido: option (defaults to global)
    task_sup = Supervisors.task_supervisor(opts)
    propagation = Propagation.capture(opts)

    parent = self()
    ref = make_ref()

    # Spawn process under the supervisor and send the result back explicitly.
    # This avoids relying on Task.yield/2 behavior/typing (Elixir 1.18+).
    {:ok, pid} =
      Task.Supervisor.start_child(task_sup, fn ->
        # Use the parent's group leader to ensure IO is properly captured
        Process.group_leader(self(), current_gl)

        result =
          Propagation.with_attached(propagation, fn ->
            execute_action(action, params, context, opts)
          end)

        send(parent, {:execute_action_result, ref, result})
      end)

    monitor_ref = Process.monitor(pid)

    # Wait for completion, crash, or timeout.
    result =
      receive do
        {:execute_action_result, ^ref, result} ->
          Process.demonitor(monitor_ref, [:flush])
          {:ok, result}

        {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
          # If the process exited normally, a result message may still be in flight.
          case reason do
            :normal ->
              receive do
                {:execute_action_result, ^ref, result} -> {:ok, result}
              after
                0 -> {:exit, reason}
              end

            _ ->
              {:exit, reason}
          end
      after
        timeout ->
          _ = Task.Supervisor.terminate_child(task_sup, pid)
          cleanup_timeout_task(ref, monitor_ref, pid)

          :timeout
      end

    case result do
      {:ok, result} ->
        result

      {:exit, reason} ->
        {:error,
         Error.execution_error(
           "Task exited: #{Telemetry.extract_safe_error_message(reason)}",
           %{
             reason: reason,
             action: action
           }
         )}

      :timeout ->
        {:error,
         Error.timeout_error(
           "Action #{inspect(action)} timed out after #{timeout}ms",
           %{
             timeout: timeout,
             action: action
           }
         )}
    end
  end

  defp cleanup_timeout_task(ref, monitor_ref, pid) do
    wait_for_task_down(monitor_ref, pid, 100)
    Process.demonitor(monitor_ref, [:flush])
    flush_execute_action_results(ref)
  end

  defp wait_for_task_down(monitor_ref, pid, wait_ms) do
    receive do
      {:DOWN, ^monitor_ref, :process, ^pid, _reason} ->
        :ok
    after
      wait_ms ->
        if Process.alive?(pid), do: Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
        after
          wait_ms -> :ok
        end
    end
  end

  defp flush_execute_action_results(ref) do
    receive do
      {:execute_action_result, ^ref, _result} ->
        flush_execute_action_results(ref)
    after
      0 ->
        :ok
    end
  end

  defp resolve_timeout_budget(context, opts) do
    timeout = resolve_timeout_opt(opts)
    existing_deadline = Map.get(context, @deadline_key)

    if timeout == 0 and not is_integer(existing_deadline) do
      {:ok, timeout, context}
    else
      now = System.monotonic_time(:millisecond)

      deadline =
        cond do
          is_integer(existing_deadline) and timeout > 0 ->
            min(existing_deadline, now + timeout)

          is_integer(existing_deadline) ->
            existing_deadline

          timeout > 0 ->
            now + timeout

          true ->
            nil
        end

      case deadline do
        deadline_ms when is_integer(deadline_ms) ->
          remaining = deadline_ms - now

          if remaining <= 0 do
            {:error,
             Error.timeout_error("Execution deadline exceeded before action dispatch", %{
               deadline_ms: deadline_ms,
               now_ms: now
             })}
          else
            effective_timeout = if timeout == 0, do: remaining, else: min(timeout, remaining)
            {:ok, effective_timeout, Map.put(context, @deadline_key, deadline_ms)}
          end

        _ ->
          {:ok, timeout, context}
      end
    end
  end

  defp resolve_timeout_opt(opts) do
    case Keyword.get(opts, :timeout, get_default_timeout()) do
      timeout when is_integer(timeout) and timeout >= 0 -> timeout
      _invalid -> get_default_timeout()
    end
  end

  defp apply_compat_opts(opts) do
    maybe_warn_deprecated_error_normalization_opt(opts)
    maybe_warn_deprecated_error_normalization_config()
    opts
  end

  defp maybe_warn_deprecated_error_normalization_opt(opts) do
    case Keyword.fetch(opts, @deprecated_error_normalization_key) do
      {:ok, mode} when mode in @valid_error_normalization_modes ->
        warn_deprecated_error_normalization_once(
          {:opt, mode},
          "Execution option :error_normalization=#{inspect(mode)} is deprecated and ignored. " <>
            "Jido.Exec now uses the canonical structured execution error shape unconditionally."
        )

      {:ok, invalid} ->
        warn_deprecated_error_normalization_once(
          {:opt, invalid},
          "Execution option :error_normalization=#{inspect(invalid)} is deprecated and ignored. " <>
            "Expected one of #{@valid_error_normalization_modes |> inspect()}; canonical normalization is always used."
        )

      :error ->
        :ok
    end
  end

  defp maybe_warn_deprecated_error_normalization_config do
    case Application.get_env(:jido_action, @deprecated_error_normalization_key) do
      nil ->
        :ok

      mode when mode in @valid_error_normalization_modes ->
        warn_deprecated_error_normalization_once(
          {:config, mode},
          ":jido_action config :error_normalization=#{inspect(mode)} is deprecated and ignored. " <>
            "Jido.Exec now uses the canonical structured execution error shape unconditionally."
        )

      invalid ->
        warn_deprecated_error_normalization_once(
          {:config, invalid},
          ":jido_action config :error_normalization=#{inspect(invalid)} is deprecated and ignored. " <>
            "Expected one of #{@valid_error_normalization_modes |> inspect()}; canonical normalization is always used."
        )
    end
  end

  defp warn_deprecated_error_normalization_once(key, message) do
    warning_key = {__MODULE__, @deprecated_error_normalization_key, key}

    unless :persistent_term.get(warning_key, false) do
      Logger.warning(message)
      :persistent_term.put(warning_key, true)
    end

    :ok
  end

  defp resolve_telemetry_mode(opts) do
    case Keyword.fetch(opts, :telemetry) do
      {:ok, mode} when mode in [:full, :silent] ->
        mode

      {:ok, invalid} ->
        Logger.warning(fn ->
          "Invalid execution :telemetry option: #{inspect(invalid)}. " <>
            "Expected one of [:full, :silent]; using :full."
        end)

        :full

      :error ->
        :full
    end
  end

  @spec execute_action(action(), params(), context(), run_opts()) :: exec_result
  defp execute_action(action, params, context, opts) do
    log_level = Util.resolve_log_level(opts)
    Telemetry.cond_log_start(log_level, action, params, context)

    action.run(params, context)
    |> handle_action_result(action, log_level, opts)
  rescue
    e ->
      handle_action_exception(e, __STACKTRACE__, action, opts)
  end

  # Handle successful results with extra data
  defp handle_action_result({:ok, result, other}, action, log_level, opts) do
    validate_and_log_success(action, result, log_level, opts, other)
  end

  # Handle successful results
  defp handle_action_result({:ok, result}, action, log_level, opts) do
    validate_and_log_success(action, result, log_level, opts, nil)
  end

  # Handle errors with extra data
  defp handle_action_result({:error, %_{} = error, other}, action, log_level, _opts)
       when is_exception(error) do
    Telemetry.cond_log_error(log_level, action, error)
    {:error, error, other}
  end

  defp handle_action_result({:error, reason, other}, action, log_level, _opts) do
    Telemetry.cond_log_error(log_level, action, reason)
    {message, details} = extract_error_fields(reason)
    {:error, Error.execution_error(message, details), other}
  end

  # Handle exception errors
  defp handle_action_result({:error, %_{} = error}, action, log_level, _opts)
       when is_exception(error) do
    Telemetry.cond_log_error(log_level, action, error)
    {:error, error}
  end

  # Handle generic errors — normalize reason into a well-formed
  # ExecutionFailureError with a string message and structured details.
  defp handle_action_result({:error, reason}, action, log_level, _opts) do
    Telemetry.cond_log_error(log_level, action, reason)
    {message, details} = extract_error_fields(reason)
    {:error, Error.execution_error(message, details)}
  end

  # Handle unexpected return shapes
  defp handle_action_result(unexpected_result, action, log_level, _opts) do
    error =
      Error.execution_error(
        "Unexpected return shape: #{Telemetry.extract_safe_error_message(unexpected_result)}"
      )

    Telemetry.cond_log_error(log_level, action, error)
    {:error, error}
  end

  defp extract_error_fields(%{message: message} = reason)
       when is_struct(reason) and is_binary(message) do
    {Telemetry.extract_safe_error_message(reason), struct_error_details(reason)}
  end

  defp extract_error_fields(%{message: message} = reason) when is_struct(reason) do
    {Telemetry.extract_safe_error_message(%{message: message}), struct_error_details(reason)}
  end

  defp extract_error_fields(%{message: message} = reason) when is_binary(message) do
    {Telemetry.extract_safe_error_message(reason), Map.delete(reason, :message)}
  end

  defp extract_error_fields(%{message: message} = reason) do
    {Telemetry.extract_safe_error_message(%{message: message}), Map.delete(reason, :message)}
  end

  defp extract_error_fields(reason) when is_binary(reason),
    do: {Telemetry.extract_safe_error_message(%{message: reason}), %{}}

  defp extract_error_fields(reason) when is_atom(reason),
    do: {Atom.to_string(reason), %{reason: reason}}

  defp extract_error_fields(reason) when is_map(reason),
    do: {Telemetry.extract_safe_error_message(reason), reason}

  defp extract_error_fields(reason), do: {Telemetry.extract_safe_error_message(reason), %{}}

  defp struct_error_details(reason) do
    reason
    |> Map.from_struct()
    |> Map.drop([:__exception__, :message])
  end

  # Validate output and log success, with optional extra data
  defp validate_and_log_success(action, result, log_level, opts, other) do
    case Validator.validate_output(action, result, opts) do
      {:ok, validated_result} ->
        log_validated_success(action, validated_result, log_level, other)

      {:error, validation_error} ->
        log_validation_failure(action, validation_error, log_level, other)
    end
  end

  defp log_validated_success(action, validated_result, log_level, nil) do
    Telemetry.cond_log_end(log_level, action, {:ok, validated_result})
    {:ok, validated_result}
  end

  defp log_validated_success(action, validated_result, log_level, other) do
    Telemetry.cond_log_end(log_level, action, {:ok, validated_result, other})
    {:ok, validated_result, other}
  end

  defp log_validation_failure(action, validation_error, log_level, nil) do
    Telemetry.cond_log_validation_failure(log_level, action, validation_error)
    {:error, validation_error}
  end

  defp log_validation_failure(action, validation_error, log_level, other) do
    Telemetry.cond_log_validation_failure(log_level, action, validation_error)
    {:error, validation_error, other}
  end

  # Handle exceptions raised during action execution
  defp handle_action_exception(e, stacktrace, action, opts) do
    log_level = Util.resolve_log_level(opts)
    Telemetry.cond_log_error(log_level, action, e)

    error_message = build_exception_message(e, action)

    {:error,
     Error.execution_error(error_message, %{
       original_exception: e,
       action: action,
       stacktrace: stacktrace
     })}
  end

  defp build_exception_message(%RuntimeError{} = e, action) do
    "Server error in #{inspect(action)}: #{Telemetry.extract_safe_error_message(e)}"
  end

  defp build_exception_message(%ArgumentError{} = e, action) do
    "Argument error in #{inspect(action)}: #{Telemetry.extract_safe_error_message(e)}"
  end

  defp build_exception_message(e, action) do
    "An unexpected error occurred during execution of #{inspect(action)}: #{Telemetry.extract_safe_error_message(e)}"
  end
end
