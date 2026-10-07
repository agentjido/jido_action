defmodule Jido.Exec do
  @moduledoc """
  Compiles and runs Jido Actions and Flows with Runic.

  One Action is compiled as a one-node Runic Workflow. A Flow is compiled as
  a larger Runic Workflow. Runic owns runnable preparation, execution policy,
  graph updates, and durable runtime state.
  """

  alias Jido.Exec.{Compiler, Frame, Portable, Telemetry}
  alias Jido.Instruction
  alias Runic.Workflow
  alias Runic.Workflow.{Fact, RunnableFailed, SchedulerPolicy}

  @default_task_supervisor Jido.Exec.TaskSupervisor

  @typedoc "A local Task Supervisor PID, registered name, or via reference."
  @type task_supervisor :: pid() | atom() | {:via, module(), term()}

  @type exec_result ::
          {:ok, term()}
          | {:ok, term(), [term()]}
          | {:error, Exception.t() | term()}

  @type step_result ::
          {:ok, Workflow.t()}
          | {:complete, Workflow.t()}
          | {:error, term()}

  @doc "Compiles an Action, Instruction, Flow module, or Flow value to Runic."
  @spec compile(term(), keyword()) :: {:ok, Workflow.t()} | {:error, Exception.t()}
  def compile(target, opts \\ []), do: Compiler.compile(target, opts)

  @doc "Compiles an executable target to Runic or raises its error."
  @spec compile!(term(), keyword()) :: Workflow.t() | no_return()
  def compile!(target, opts \\ []), do: Compiler.compile!(target, opts)

  @doc "Derives a stable identity for one deferred effect in a completed Runic output."
  @spec effect_id(term(), Runic.Identity.t(), Runic.Identity.t(), non_neg_integer()) ::
          Runic.Identity.t()
  def effect_id(execution_id, activation_id, output_id, index)
      when is_integer(index) and index >= 0 do
    Runic.Identity.digest(:event_data, %{
      kind: :jido_effect,
      version: 1,
      execution_id: execution_id,
      activation_id: activation_id,
      output_id: output_id,
      index: index
    })
  end

  @doc """
  Runs an Action or Flow to completion with the in-memory Runic runtime.

  The complete execution runs in an unlinked temporary task under
  `Jido.Exec.TaskSupervisor`. The task keeps the caller's group leader. Pass
  `task_supervisor: reference` to use another local Task Supervisor.
  """
  @spec run(term(), map() | keyword() | nil, map() | keyword() | nil, keyword()) :: exec_result()
  def run(target, params \\ %{}, context \\ %{}, opts \\ []) do
    group_leader = Process.group_leader()

    with {:ok, task_supervisor, execution_opts} <- run_options(opts) do
      run_supervised(task_supervisor, group_leader, fn ->
        do_run(target, params, context, execution_opts)
      end)
    end
  end

  defp do_run(target, params, context, opts) do
    with {:ok, instruction} <- Instruction.resolve(target, params, context) do
      run_instruction(instruction, opts)
    else
      {:error, error} -> {:error, normalize_runtime_error(error)}
    end
  end

  defp run_instruction(%Instruction{kind: :flow} = instruction, opts) do
    Telemetry.span(:flow, Telemetry.flow_metadata(instruction), fn ->
      do_run_instruction(instruction, opts)
    end)
  end

  defp run_instruction(%Instruction{} = instruction, opts) do
    do_run_instruction(instruction, opts)
  end

  defp do_run_instruction(instruction, opts) do
    with {:ok, instruction} <- validate_flow_input(instruction),
         {:ok, workflow} <- compile(instruction),
         {:ok, workflow, last_fact} <-
           run_workflow(workflow, execution_input(instruction), instruction.context, opts) do
      project(last_fact, workflow)
    else
      {:error, error} -> {:error, normalize_runtime_error(error)}
    end
  end

  @doc "Starts one managed execution under an existing Runic Runner."
  @spec start(
          module(),
          term(),
          term(),
          map() | keyword() | nil,
          map() | keyword() | nil,
          keyword()
        ) :: DynamicSupervisor.on_start_child()
  def start(runner, execution_id, target, params \\ %{}, context \\ %{}, opts \\ []) do
    with {:ok, instruction} <- Instruction.resolve(target, params, context),
         {:ok, instruction} <- validate_flow_input(instruction),
         :ok <- validate_durable_instruction(instruction),
         {:ok, workflow} <- compile(instruction),
         {:ok, policy, worker_opts} <- managed_options(runner, opts),
         {:ok, pid} <-
           Runic.Runner.start_workflow(runner, execution_id, workflow, worker_opts),
         :ok <-
           Runic.Runner.run(runner, execution_id, execution_input(instruction),
             run_context: %{_global: durable_context(instruction.context)},
             scheduler_policies: [{:default, Map.from_struct(policy)}]
           ) do
      {:ok, pid}
    else
      {:error, error} -> {:error, normalize_runtime_error(error)}
    end
  end

  @doc """
  Dispatches one Runic scheduler unit for a manually dispatched execution.

  Start the execution with `dispatch_mode: :manual`. The default scheduler
  dispatches one Runnable per call. A custom batching scheduler can define a
  larger unit.

  `{:ok, workflow}` means that Runic dispatched one unit. The returned
  workflow is the current Runic state and the unit can still be active. Retry
  after `{:error, :busy}` when that unit completes.

  `{:complete, workflow}` means that Runic has no ready work. Inspect the
  workflow results and events to distinguish successful completion from a
  terminal failure.
  """
  @spec step(module(), term()) :: step_result()
  def step(runner, execution_id) do
    case Runic.Runner.step(runner, execution_id) do
      :ok -> current_workflow(runner, execution_id, :ok)
      {:error, :not_runnable} -> current_workflow(runner, execution_id, :complete)
      {:error, _reason} = error -> error
    end
  end

  defp run_workflow(workflow, input, context, opts) do
    with {:ok, policy, react_opts} <- execution_options(opts) do
      workflow =
        workflow
        |> Workflow.enable_event_emission()
        |> Workflow.put_run_context(%{_global: context})
        |> Workflow.react_until_satisfied(
          Fact.new(value: input),
          Keyword.merge(react_opts,
            scheduler_policies: [{:default, Map.from_struct(policy)}]
          )
        )

      case last_failure(workflow) do
        nil -> {:ok, workflow, result_fact(workflow)}
        error -> {:error, error}
      end
    end
  end

  defp result_fact(workflow) do
    case Workflow.results(workflow, nil, facts: true) do
      %{result: %Runic.Workflow.Fact{} = fact} -> fact
      _ -> nil
    end
  end

  defp project(last_fact, workflow) do
    case Workflow.results(workflow, nil, facts: true) do
      %{result: %Runic.Workflow.Fact{} = fact} -> project_fact(fact)
      _ -> project_last(last_fact, workflow)
    end
  end

  defp project_last(nil, _workflow),
    do: {:error, Jido.Action.Error.execution_error("Exec produced no result")}

  defp project_last(%Runic.Workflow.Fact{} = fact, _workflow), do: project_fact(fact)

  defp project_fact(%Runic.Workflow.Fact{value: value, meta: meta}) do
    effects = get_in(meta, [:jido, :effects]) || []
    if effects == [], do: {:ok, value}, else: {:ok, value, effects}
  end

  defp last_failure(%Workflow{runnable_events: events}) do
    events
    |> Enum.reverse()
    |> Enum.find_value(fn
      %RunnableFailed{error: error} -> error
      _event -> nil
    end)
  end

  defp execution_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      allowed = [
        :timeout,
        :max_attempts,
        :backoff,
        :base_delay_ms,
        :max_delay_ms,
        :max_concurrency
      ]

      case Keyword.keys(opts) -- allowed do
        [] ->
          case build_policy(opts) do
            {:ok, policy} ->
              max_concurrency = Keyword.get(opts, :max_concurrency, 1)

              react_opts =
                if max_concurrency > 1,
                  do: [async: true, max_concurrency: max_concurrency],
                  else: []

              {:ok, policy, react_opts}

            {:error, error} ->
              {:error, error}
          end

        unknown ->
          {:error,
           Jido.Action.Error.config_error("unknown execution options", %{options: unknown})}
      end
    else
      {:error, Jido.Action.Error.config_error("execution options must be a keyword list")}
    end
  end

  defp run_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      case Keyword.get_values(opts, :task_supervisor) do
        [] ->
          with :ok <- validate_task_supervisor(@default_task_supervisor) do
            {:ok, @default_task_supervisor, opts}
          end

        [task_supervisor] ->
          with :ok <- validate_task_supervisor(task_supervisor) do
            {:ok, task_supervisor, Keyword.delete(opts, :task_supervisor)}
          end

        _duplicates ->
          {:error,
           Jido.Action.Error.config_error("pass only one task_supervisor reference", %{
             option: :task_supervisor,
             reason: :duplicate_option
           })}
      end
    else
      {:error, Jido.Action.Error.config_error("execution options must be a keyword list")}
    end
  end

  defp run_options(_opts),
    do: {:error, Jido.Action.Error.config_error("execution options must be a keyword list")}

  defp validate_task_supervisor(task_supervisor)
       when is_pid(task_supervisor) or
              (is_atom(task_supervisor) and task_supervisor not in [nil, true, false]) or
              (is_tuple(task_supervisor) and tuple_size(task_supervisor) == 3 and
                 elem(task_supervisor, 0) == :via) do
    case GenServer.whereis(task_supervisor) do
      pid when is_pid(pid) and node(pid) == node() ->
        :ok

      _other ->
        {:error,
         Jido.Action.Error.config_error("Task Supervisor is not running", %{
           option: :task_supervisor,
           task_supervisor: task_supervisor
         })}
    end
  rescue
    exception ->
      {:error,
       Jido.Action.Error.config_error("Task Supervisor lookup failed", %{
         option: :task_supervisor,
         task_supervisor: task_supervisor,
         reason: exception
       })}
  catch
    kind, reason ->
      {:error,
       Jido.Action.Error.config_error("Task Supervisor lookup failed", %{
         option: :task_supervisor,
         task_supervisor: task_supervisor,
         reason: {kind, reason}
       })}
  end

  defp validate_task_supervisor(task_supervisor) do
    {:error,
     Jido.Action.Error.config_error(
       "task_supervisor must be a local PID, registered name, or {:via, module, name} reference",
       %{option: :task_supervisor, value: task_supervisor}
     )}
  end

  defp run_supervised(task_supervisor, group_leader, work) do
    caller = self()

    task =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        Process.group_leader(self(), group_leader)
        watcher = watch_caller(caller, self())
        result = work.()
        stop_watcher(watcher)
        result
      end)

    case Task.yield(task, :infinity) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, execution_task_error(reason)}
      nil -> {:error, execution_task_error(:no_result)}
    end
  rescue
    exception ->
      {:error, execution_task_error(exception)}
  catch
    kind, reason ->
      {:error, execution_task_error({kind, reason})}
  end

  # The execution task is not linked to the caller, so a killed Action cannot
  # exit the caller. This linked watcher kills the task, and the processes
  # linked to it, when the caller exits.
  defp watch_caller(caller, task) do
    spawn_link(fn ->
      monitor = Process.monitor(caller)

      receive do
        {:DOWN, ^monitor, :process, ^caller, _reason} -> Process.exit(task, :kill)
      end
    end)
  end

  defp stop_watcher(watcher) do
    Process.unlink(watcher)
    Process.exit(watcher, :kill)
  end

  defp execution_task_error(reason) do
    Jido.Action.Error.execution_error("Exec task exited", %{
      phase: :execution_task,
      reason: reason
    })
  end

  defp managed_options(runner, opts) when is_list(opts) do
    policy_keys = [:timeout, :max_attempts, :backoff, :base_delay_ms, :max_delay_ms]

    worker_keys = [
      :dispatch_mode,
      :max_concurrency,
      :on_complete,
      :checkpoint_strategy,
      :executor,
      :executor_opts,
      :scheduler,
      :scheduler_opts,
      :hooks,
      :promise_opts
    ]

    if Keyword.keyword?(opts) do
      case Keyword.keys(opts) -- (policy_keys ++ worker_keys) do
        [] ->
          with {:ok, policy} <- build_policy(Keyword.take(opts, policy_keys)) do
            policy = %{policy | execution_mode: :durable}
            worker_opts = Keyword.take(opts, worker_keys)
            {:ok, policy, default_executor(runner, worker_opts)}
          end

        unknown ->
          {:error,
           Jido.Action.Error.config_error("unknown managed execution options", %{
             options: unknown
           })}
      end
    else
      {:error, Jido.Action.Error.config_error("execution options must be a keyword list")}
    end
  end

  defp managed_options(_runner, _opts),
    do: {:error, Jido.Action.Error.config_error("execution options must be a keyword list")}

  defp default_executor(runner, opts) do
    if Keyword.has_key?(opts, :executor) do
      opts
    else
      opts
      |> Keyword.put(:executor, Jido.Exec.Runner.TaskExecutor)
      |> Keyword.put(
        :executor_opts,
        task_supervisor: Module.concat(runner, TaskSupervisor)
      )
    end
  end

  defp current_workflow(runner, execution_id, status) do
    case Runic.Runner.get_workflow(runner, execution_id) do
      {:ok, %Workflow{} = workflow} -> {status, workflow}
      {:error, _reason} = error -> error
    end
  end

  defp build_policy(opts) do
    timeout = Keyword.get(opts, :timeout, :infinity)
    max_attempts = Keyword.get(opts, :max_attempts, 1)
    backoff = Keyword.get(opts, :backoff, :none)
    base_delay_ms = Keyword.get(opts, :base_delay_ms, 0)
    max_delay_ms = Keyword.get(opts, :max_delay_ms, 0)

    cond do
      timeout != :infinity and not (is_integer(timeout) and timeout >= 0) ->
        {:error, Jido.Action.Error.config_error("timeout must be non-negative or :infinity")}

      not (is_integer(max_attempts) and max_attempts >= 1) ->
        {:error, Jido.Action.Error.config_error("max_attempts must be a positive integer")}

      backoff not in [:none, :linear, :exponential, :jitter] ->
        {:error, Jido.Action.Error.config_error("invalid backoff policy")}

      not (is_integer(base_delay_ms) and base_delay_ms >= 0) ->
        {:error, Jido.Action.Error.config_error("base_delay_ms must be non-negative")}

      not (is_integer(max_delay_ms) and max_delay_ms >= 0) ->
        {:error, Jido.Action.Error.config_error("max_delay_ms must be non-negative")}

      true ->
        {:ok,
         %SchedulerPolicy{
           timeout_ms: timeout,
           max_retries: max_attempts - 1,
           backoff: backoff,
           base_delay_ms: base_delay_ms,
           max_delay_ms: max_delay_ms,
           on_failure: :halt
         }}
    end
  end

  defp normalize_runtime_error(error) when is_exception(error), do: error

  defp normalize_runtime_error({:timeout, timeout}) do
    Jido.Action.Error.timeout_error("Action timed out", %{timeout: timeout})
  end

  defp normalize_runtime_error({:deadline_exceeded, remaining_ms}) do
    Jido.Action.Error.timeout_error("Execution deadline was exceeded", %{
      remaining_ms: remaining_ms
    })
  end

  defp normalize_runtime_error(reason) do
    Jido.Action.Error.execution_error("Runic execution failed", %{reason: reason})
  end

  defp execution_input(%Instruction{kind: :action}), do: %{}
  defp execution_input(%Instruction{kind: :flow, params: params}), do: Frame.new(params)

  defp validate_durable_instruction(%Instruction{} = instruction) do
    with :ok <- Portable.validate(instruction.params, :params) do
      Portable.validate(instruction.context, :context)
    end
  end

  defp durable_context(context), do: Map.put(context, :__jido_exec_durable__, true)

  defp validate_flow_input(%Instruction{kind: :action} = instruction), do: {:ok, instruction}

  defp validate_flow_input(%Instruction{kind: :flow, target: module} = instruction)
       when is_atom(module) do
    case module.validate_params(instruction.params) do
      {:ok, params} -> {:ok, %{instruction | params: params}}
      {:error, error} -> {:error, put_error_phase(error, :flow_input)}
    end
  end

  defp validate_flow_input(%Instruction{kind: :flow, target: %Jido.Flow{} = flow} = instruction) do
    case validate_flow_input_value(flow.schema, instruction.params, flow.name) do
      {:ok, params} -> {:ok, %{instruction | params: params}}
      {:error, error} -> {:error, put_error_phase(error, :flow_input)}
    end
  end

  defp put_error_phase(%{details: details} = error, phase) when is_map(details),
    do: %{error | details: Map.put(details, :phase, phase)}

  defp put_error_phase(error, _phase), do: error

  defp validate_flow_input_value(schema, value, name) do
    with {:ok, validated} <-
           Jido.Action.Validation.open_validate(schema, value, %{
             module: Jido.Flow,
             flow: name,
             context: "Flow"
           }) do
      if is_map(validated) do
        {:ok, validated}
      else
        {:error,
         Jido.Action.Error.validation_error("Flow input must be a map", %{
           flow: name,
           value: validated
         })}
      end
    end
  end
end
