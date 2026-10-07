defmodule Jido.Exec do
  @moduledoc """
  Compiles and runs Jido Actions and Flows with Runic.

  One Action is compiled as a one-node Runic Workflow. A Flow is compiled as
  a larger Runic Workflow. Runic owns runnable preparation, execution policy,
  graph updates, and durable runtime state.
  """

  alias Jido.Exec.{Compiler, Frame, Portable}
  alias Jido.Instruction
  alias Runic.Workflow
  alias Runic.Workflow.{Fact, RunnableFailed, SchedulerPolicy}

  @type exec_result ::
          {:ok, term()}
          | {:ok, term(), [term()]}
          | {:error, Exception.t() | term()}

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

  @doc "Runs an Action or Flow to completion with the in-memory Runic runtime."
  @spec run(term(), map() | keyword() | nil, map() | keyword() | nil, keyword()) :: exec_result()
  def run(target, params \\ %{}, context \\ %{}, opts \\ []) do
    with {:ok, instruction} <- Instruction.resolve(target, params, context),
         {:ok, instruction} <- validate_flow_input(instruction),
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

  defp execution_options(_opts),
    do: {:error, Jido.Action.Error.config_error("execution options must be a keyword list")}

  defp managed_options(runner, opts) when is_list(opts) do
    policy_keys = [:timeout, :max_attempts, :backoff, :base_delay_ms, :max_delay_ms]

    worker_keys = [
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
