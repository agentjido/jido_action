defmodule Jido.Exec do
  @moduledoc """
  Runic-backed execution facade for Jido flows.

  `Jido.Exec` accepts Jido action modules, `Jido.Instruction` values, and
  `Jido.Flow` values. Bare actions and instructions are normalized into
  one-step flows; composed flows are projected into Runic workflows at the
  runtime boundary. Retry, timeout, fallback, scheduling, and durable execution
  are owned by Runic.
  """

  alias Jido.Action.Error
  alias Jido.Exec.{Result, Telemetry}
  alias Jido.Flow
  alias Jido.Instruction
  alias Runic.Workflow
  alias Runic.Workflow.{Fact, PolicyDriver, Runnable, SchedulerPolicy}

  @no_input {__MODULE__, :no_input}

  @type executable :: module() | Instruction.t() | Flow.t()
  @type run_opts :: keyword()

  @doc """
  Executes an action, instruction, or flow to quiescence.

  Bare actions are converted to one-step flows with empty params. Instructions
  are converted to one-step flows using their embedded params and context.
  Use `:run_context` for runtime context and `:scheduler_policies` for runtime
  policy overrides. Flat `:run_context` maps are treated as global Jido action
  context. Runic-shaped context remains available with `:_global` or
  component-name keys. Bare actions and instructions may pass `:name` to choose
  the one-step flow component name explicitly.
  """
  @spec run(executable()) :: {:ok, Result.t()} | {:error, Result.t()} | {:error, Exception.t()}
  def run(%Flow{} = flow), do: run_flow(flow, @no_input, [])
  def run(%Instruction{} = instruction), do: run_instruction(instruction, @no_input, [])
  def run(action) when is_atom(action) and not is_nil(action), do: run_action(action, %{}, [])
  def run(other), do: unsupported_executable(other)

  @spec run(executable(), term()) ::
          {:ok, Result.t()} | {:error, Result.t()} | {:error, Exception.t()}
  def run(%Flow{} = flow, input), do: run_flow(flow, input, [])
  def run(%Instruction{} = instruction, input), do: run_instruction(instruction, input, [])

  def run(action, params) when is_atom(action) and not is_nil(action),
    do: run_action(action, params, [])

  def run(other, _input), do: unsupported_executable(other)

  @spec run(executable(), term(), run_opts()) ::
          {:ok, Result.t()} | {:error, Result.t()} | {:error, Exception.t()}
  def run(%Flow{} = flow, input, opts) when is_list(opts),
    do: run_flow(flow, input, opts)

  def run(%Instruction{} = instruction, input, opts) when is_list(opts),
    do: run_instruction(instruction, input, opts)

  def run(action, params, opts) when is_atom(action) and not is_nil(action) and is_list(opts),
    do: run_action(action, params, opts)

  def run(other, _input, _opts), do: unsupported_executable(other)

  @doc """
  Performs one Runic prepare/dispatch/apply cycle.
  """
  @spec step(executable()) ::
          {:ok, Result.t()} | {:error, Result.t()} | {:error, Exception.t()}
  def step(%Flow{} = flow), do: step_flow(flow, @no_input, [])
  def step(%Instruction{} = instruction), do: step_instruction(instruction, @no_input, [])
  def step(action) when is_atom(action) and not is_nil(action), do: step_action(action, %{}, [])
  def step(other), do: unsupported_executable(other)

  @spec step(executable(), term()) ::
          {:ok, Result.t()} | {:error, Result.t()} | {:error, Exception.t()}
  def step(%Flow{} = flow, input), do: step_flow(flow, input, [])
  def step(%Instruction{} = instruction, input), do: step_instruction(instruction, input, [])

  def step(action, params) when is_atom(action) and not is_nil(action),
    do: step_action(action, params, [])

  def step(other, _input), do: unsupported_executable(other)

  @spec step(executable(), term(), keyword()) ::
          {:ok, Result.t()} | {:error, Result.t()} | {:error, Exception.t()}
  def step(%Flow{} = flow, input, opts) when is_list(opts), do: step_flow(flow, input, opts)

  def step(%Instruction{} = instruction, input, opts) when is_list(opts),
    do: step_instruction(instruction, input, opts)

  def step(action, params, opts) when is_atom(action) and not is_nil(action) and is_list(opts),
    do: step_action(action, params, opts)

  def step(other, _input, _opts), do: unsupported_executable(other)

  @doc """
  Continues a local execution result and runs it to quiescence.

  If no input is supplied, queued work resumes without adding a new runtime
  fact. Supplying input appends a new fact before continuing.
  """
  @spec resume(Result.t()) :: {:ok, Result.t()} | {:error, Result.t()} | {:error, Exception.t()}
  def resume(%Result{} = result), do: resume(result, @no_input, [])
  def resume(other), do: unsupported_result(other)

  @spec resume(Result.t(), term(), keyword()) ::
          {:ok, Result.t()} | {:error, Result.t()} | {:error, Exception.t()}
  def resume(%Result{} = result, input), do: resume(result, input, [])
  def resume(other, _input), do: unsupported_result(other)

  def resume(%Result{status: status} = result, input, opts)
      when status in [:ok, :max_cycles] and is_list(opts) do
    run_workflow(result.workflow, input, opts)
  end

  def resume(%Result{status: status}, _input, opts) when is_list(opts) do
    {:error,
     Error.validation_error("cannot resume failed execution result", %{
       status: status
     })}
  end

  def resume(other, _input, _opts), do: unsupported_result(other)

  @doc """
  Returns runtime results from an execution result.
  """
  @spec results(Result.t(), keyword()) :: term()
  def results(%Result{} = result), do: results(result, [])
  def results(other), do: unsupported_result(other)

  def results(%Result{} = result, opts) when is_list(opts) do
    with :ok <- validate_result_options(opts) do
      do_results(result, opts)
    end
  end

  def results(other, _opts), do: unsupported_result(other)

  @doc """
  Returns durable and in-memory events associated with an execution result.
  """
  @spec events(Result.t(), keyword()) :: [term()] | {:error, Exception.t()}
  def events(result, opts \\ [])

  def events(%Result{} = result, opts) when is_list(opts) do
    with :ok <- validate_event_options(opts) do
      do_events(result, opts)
    end
  end

  def events(other, _opts), do: unsupported_result(other)

  @doc """
  Returns a compact execution summary for an execution result.
  """
  @spec summary(Result.t()) :: map() | {:error, Exception.t()}
  def summary(%Result{} = result), do: do_summary(result)
  def summary(other), do: unsupported_result(other)

  @doc """
  Walks a produced fact's ancestry through the result workflow.
  """
  @spec provenance(Result.t(), term()) ::
          {:ok, [Runic.Workflow.Fact.t()]} | {:error, :not_found} | {:error, Exception.t()}
  def provenance(%Result{} = result, fact_hash) do
    do_provenance(result, fact_hash)
  end

  def provenance(other, _fact_hash), do: unsupported_result(other)

  defp run_flow(%Flow{} = flow, input, opts) do
    flow
    |> Flow.to_workflow()
    |> run_workflow(input, opts)
  rescue
    error in [ArgumentError] ->
      {:error, Error.validation_error(Exception.message(error), %{value: flow})}
  end

  defp run_instruction(%Instruction{} = instruction, input, opts) do
    {name, opts} = Keyword.pop(opts, :name)

    with :ok <- validate_direct_action_contract(instruction.action),
         {:ok, flow} <- one_step_flow(instruction, name) do
      run_flow(flow, one_step_input(input), opts)
    end
  end

  defp run_action(action, params, opts) do
    {name, opts} = Keyword.pop(opts, :name)

    with :ok <- validate_direct_action_contract(action),
         {:ok, flow} <- one_step_flow(action, params, name) do
      run_flow(flow, %{}, opts)
    end
  end

  defp step_flow(%Flow{} = flow, input, opts) do
    flow
    |> Flow.to_workflow()
    |> step_workflow(input, opts)
  rescue
    error in [ArgumentError] ->
      {:error, Error.validation_error(Exception.message(error), %{value: flow})}
  end

  defp step_instruction(%Instruction{} = instruction, input, opts) do
    {name, opts} = Keyword.pop(opts, :name)

    with :ok <- validate_direct_action_contract(instruction.action),
         {:ok, flow} <- one_step_flow(instruction, name) do
      step_flow(flow, one_step_input(input), opts)
    end
  end

  defp step_action(action, params, opts) do
    {name, opts} = Keyword.pop(opts, :name)

    with :ok <- validate_direct_action_contract(action),
         {:ok, flow} <- one_step_flow(action, params, name) do
      step_flow(flow, %{}, opts)
    end
  end

  defp run_workflow(%Workflow{} = workflow, input, opts) do
    with :ok <- validate_run_context(Keyword.get(opts, :run_context)),
         :ok <- validate_max_cycles(Keyword.get(opts, :max_cycles, :infinity)),
         :ok <- validate_scheduler_options(opts) do
      workflow
      |> start_workflow(input, opts)
      |> continue_workflow(opts, 0)
    end
  end

  defp step_workflow(%Workflow{} = workflow, input, opts) do
    with :ok <- validate_run_context(Keyword.get(opts, :run_context)),
         :ok <- validate_scheduler_options(opts) do
      workflow
      |> start_workflow(input, opts)
      |> execute_cycle(opts, 0)
      |> case do
        {:ok, workflow, cycles} ->
          {:ok, Result.new(workflow, :ok, cycles: cycles)}

        {:error, workflow, failed_runnable, cycles} ->
          Result.failed(workflow, failed_runnable, cycles: cycles)
      end
    end
  end

  defp start_workflow(%Workflow{} = workflow, input, opts) do
    workflow
    |> maybe_apply_run_context(opts)
    |> maybe_plan_input(input)
  end

  defp maybe_apply_run_context(workflow, opts) do
    case Keyword.get(opts, :run_context) do
      nil ->
        workflow

      context when is_map(context) ->
        Workflow.put_run_context(workflow, normalize_run_context(workflow, context))
    end
  end

  defp normalize_run_context(%Workflow{} = workflow, context) do
    if runic_context?(workflow, context) do
      context
    else
      %{_global: context}
    end
  end

  defp runic_context?(%Workflow{} = workflow, context) do
    Map.has_key?(context, :_global) or
      Map.has_key?(context, "_global") or
      Enum.any?(Map.keys(Workflow.components(workflow)), &Map.has_key?(context, &1))
  end

  defp maybe_plan_input(%Workflow{} = workflow, @no_input), do: workflow
  defp maybe_plan_input(%Workflow{} = workflow, nil), do: workflow

  defp maybe_plan_input(%Workflow{} = workflow, %Fact{} = fact) do
    Workflow.plan_eagerly(workflow, fact)
  end

  defp maybe_plan_input(%Workflow{} = workflow, value) do
    Workflow.plan_eagerly(workflow, value)
  end

  defp continue_workflow(%Workflow{} = workflow, opts, cycles) do
    max_cycles = Keyword.get(opts, :max_cycles, :infinity)

    cond do
      max_cycles != :infinity and cycles >= max_cycles ->
        Result.max_cycles(workflow, max_cycles, cycles: cycles)

      Workflow.is_runnable?(workflow) ->
        case execute_cycle(workflow, opts, cycles) do
          {:ok, workflow, cycles} ->
            maybe_checkpoint(opts, workflow)
            continue_workflow(workflow, opts, cycles)

          {:error, workflow, failed_runnable, cycles} ->
            Result.failed(workflow, failed_runnable, cycles: cycles)
        end

      true ->
        {:ok, Result.new(workflow, :ok, cycles: cycles)}
    end
  end

  defp execute_cycle(%Workflow{} = workflow, opts, cycles) do
    {workflow, runnables} = Workflow.prepare_for_dispatch(workflow)
    policies = effective_policies(workflow, opts)
    driver_opts = policy_driver_opts(opts)

    {workflow, failed_runnable} =
      Enum.reduce(runnables, {workflow, nil}, fn runnable, {workflow, failed} ->
        {executed, runnable_events} = execute_runnable(runnable, policies, driver_opts, opts)

        workflow =
          workflow
          |> Workflow.apply_runnable(executed)
          |> Workflow.append_runnable_events(runnable_events)

        failed = failed || failed_runnable(executed)

        {workflow, failed}
      end)

    cycles = cycles + 1

    case failed_runnable do
      %Runnable{} = runnable -> {:error, workflow, runnable, cycles}
      nil -> {:ok, workflow, cycles}
    end
  end

  defp execute_runnable(%Runnable{} = runnable, policies, driver_opts, opts) do
    policy = SchedulerPolicy.resolve(runnable, policies)
    driver_opts = Keyword.put(driver_opts, :emit_events, true)

    result =
      case action_span_context(runnable, opts) do
        {action, context, span_opts} ->
          Telemetry.span(action, context, span_opts, fn ->
            execute_runnable_in_worker(runnable, policy, driver_opts)
          end)

        nil ->
          execute_runnable_in_worker(runnable, policy, driver_opts)
      end

    normalize_worker_result(result, runnable)
  end

  defp action_span_context(
         %Runnable{
           node: %Jido.Flow.Step{instruction: instruction},
           context: %{run_context: run_context}
         },
         opts
       )
       when is_map(run_context) do
    context = Map.merge(instruction.context, run_context)
    span_opts = Keyword.take(opts, [:jido])

    {instruction.action, context, span_opts}
  end

  defp action_span_context(_runnable, _opts), do: nil

  defp execute_runnable_in_worker(
         %Runnable{} = runnable,
         %SchedulerPolicy{} = policy,
         driver_opts
       ) do
    parent = self()
    caller_group_leader = Process.group_leader()
    ref = make_ref()

    work = fn ->
      Process.group_leader(self(), caller_group_leader)
      send(parent, {ref, run_policy_driver(runnable, policy, driver_opts)})
    end

    with {:ok, pid} <- start_execution_worker(work) do
      monitor_ref = Process.monitor(pid)
      await_execution_worker(ref, monitor_ref, pid)
    end
  end

  defp start_execution_worker(work) do
    Task.Supervisor.start_child(Jido.Action.TaskSupervisor, work)
  end

  defp run_policy_driver(%Runnable{} = runnable, %SchedulerPolicy{} = policy, driver_opts) do
    trap_exit? = Process.flag(:trap_exit, true)

    try do
      {:ok, PolicyDriver.execute(runnable, policy, driver_opts)}
    rescue
      error ->
        {:error, normalize_policy_driver_exception(error, __STACKTRACE__)}
    catch
      kind, reason ->
        {:error,
         Error.execution_error("runnable execution exited", %{
           kind: kind,
           reason: reason
         })}
    after
      Process.flag(:trap_exit, trap_exit?)
    end
  end

  # Runic's timeout path currently lets Task.yield/2 exits surface as a
  # CaseClauseError. Keep that adapter isolated at the Runic boundary.
  defp normalize_policy_driver_exception(%CaseClauseError{term: {:exit, reason}}, _stacktrace) do
    Error.execution_error("runnable execution exited", %{kind: :exit, reason: reason})
  end

  defp normalize_policy_driver_exception(error, stacktrace) do
    Error.execution_error("runnable execution raised", %{
      reason: error,
      stacktrace: stacktrace
    })
  end

  defp await_execution_worker(ref, monitor_ref, pid) do
    receive do
      {^ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        {:error,
         Error.execution_error("runnable execution exited", %{
           kind: :exit,
           reason: reason
         })}
    end
  end

  defp normalize_worker_result({:ok, {%Runnable{} = runnable, events}}, _original),
    do: {runnable, events}

  defp normalize_worker_result({:error, %_{} = reason}, %Runnable{} = runnable)
       when is_exception(reason),
       do: {Runnable.fail(runnable, reason), []}

  defp normalize_worker_result({:error, reason}, %Runnable{} = runnable),
    do:
      {Runnable.fail(
         runnable,
         Error.execution_error("runnable execution failed", %{reason: reason})
       ), []}

  defp failed_runnable(%Runnable{status: :failed} = runnable), do: runnable
  defp failed_runnable(_runnable), do: nil

  defp effective_policies(%Workflow{} = workflow, opts) do
    runtime = opts |> Keyword.get(:scheduler_policies) |> normalize_scheduler_policies()
    base = workflow |> Map.get(:scheduler_policies, []) |> normalize_scheduler_policies()
    mode = Keyword.get(opts, :scheduler_policies_mode, :merge)

    SchedulerPolicy.merge_policies(runtime, base, mode)
  end

  defp normalize_scheduler_policies(nil), do: []

  defp normalize_scheduler_policies(policies) when is_list(policies) do
    Enum.map(policies, fn {matcher, policy} -> {matcher, normalize_scheduler_policy(policy)} end)
  end

  defp normalize_scheduler_policy(%SchedulerPolicy{} = policy), do: Map.from_struct(policy)
  defp normalize_scheduler_policy(policy) when is_map(policy), do: policy

  defp normalize_scheduler_policy(policy) when is_list(policy) do
    if Keyword.keyword?(policy), do: Map.new(policy), else: policy
  end

  defp policy_driver_opts(opts) do
    opts
    |> maybe_put_deadline_at()
    |> Keyword.take([:deadline_at])
  end

  defp maybe_put_deadline_at(opts) do
    case {Keyword.get(opts, :deadline_ms), Keyword.get(opts, :deadline_at)} do
      {nil, _deadline_at} ->
        opts

      {_deadline_ms, deadline_at} when not is_nil(deadline_at) ->
        opts

      {deadline_ms, nil} ->
        Keyword.put(opts, :deadline_at, System.monotonic_time(:millisecond) + deadline_ms)
    end
  end

  defp maybe_checkpoint(opts, workflow) do
    case Keyword.get(opts, :checkpoint) do
      checkpoint when is_function(checkpoint, 1) -> checkpoint.(workflow)
      _other -> :ok
    end
  end

  defp validate_run_context(nil), do: :ok
  defp validate_run_context(context) when is_map(context), do: :ok

  defp validate_run_context(context) do
    {:error,
     Error.validation_error(":run_context must be a map", %{
       run_context: context
     })}
  end

  defp validate_max_cycles(:infinity), do: :ok
  defp validate_max_cycles(max_cycles) when is_integer(max_cycles) and max_cycles > 0, do: :ok

  defp validate_max_cycles(max_cycles) do
    {:error,
     Error.validation_error(":max_cycles must be a positive integer", %{
       max_cycles: max_cycles
     })}
  end

  defp validate_scheduler_options(opts) do
    with :ok <- validate_scheduler_policies(Keyword.get(opts, :scheduler_policies)),
         :ok <-
           validate_scheduler_policies_mode(Keyword.get(opts, :scheduler_policies_mode, :merge)) do
      :ok
    end
  end

  defp validate_scheduler_policies(nil), do: :ok

  defp validate_scheduler_policies(policies) when is_list(policies) do
    if Enum.all?(policies, &valid_scheduler_policy_entry?/1) do
      :ok
    else
      {:error,
       Error.validation_error(
         ":scheduler_policies must be a list of {matcher, policy} tuples using map, keyword, or SchedulerPolicy values",
         %{scheduler_policies: policies}
       )}
    end
  end

  defp validate_scheduler_policies(policies) do
    {:error,
     Error.validation_error(":scheduler_policies must be a list", %{
       scheduler_policies: policies
     })}
  end

  defp validate_scheduler_policies_mode(mode) when mode in [:merge, :replace], do: :ok

  defp validate_scheduler_policies_mode(mode) do
    {:error,
     Error.validation_error(":scheduler_policies_mode must be :merge or :replace", %{
       scheduler_policies_mode: mode
     })}
  end

  defp valid_scheduler_policy_entry?({_matcher, policy}), do: valid_scheduler_policy?(policy)
  defp valid_scheduler_policy_entry?(_entry), do: false

  defp valid_scheduler_policy?(%SchedulerPolicy{}), do: true
  defp valid_scheduler_policy?(policy) when is_map(policy), do: true
  defp valid_scheduler_policy?(policy) when is_list(policy), do: Keyword.keyword?(policy)
  defp valid_scheduler_policy?(_policy), do: false

  defp validate_result_options(opts),
    do: validate_option_keys(opts, [:refresh, :raw, :components], "result")

  defp validate_event_options(opts), do: validate_option_keys(opts, [:refresh], "event")

  defp validate_option_keys(opts, allowed, label) do
    unknown = Keyword.keys(opts) -- allowed

    if unknown == [] do
      :ok
    else
      {:error,
       Error.validation_error("unsupported #{label} options", %{
         options: unknown,
         allowed: allowed
       })}
    end
  end

  defp do_results(%Result{results: results, workflow: workflow}, opts) when is_list(opts) do
    query_opts = Keyword.delete(opts, :refresh)

    if query_opts == [] and not Keyword.get(opts, :refresh, false) do
      results
    else
      do_results(workflow, query_opts)
    end
  end

  defp do_results(%Result{workflow: workflow}, opts), do: do_results(workflow, opts)

  defp do_results(flow_or_workflow, opts) when is_list(opts) do
    workflow = result_workflow(flow_or_workflow)

    Result.workflow_results(workflow, opts)
  end

  defp do_events(%Result{events: events, workflow: workflow}, opts) when is_list(opts) do
    if Keyword.get(opts, :refresh, false) do
      do_events(workflow, [])
    else
      events
    end
  end

  defp do_events(%Result{workflow: workflow}, opts), do: do_events(workflow, opts)

  defp do_events(flow_or_workflow, _opts) do
    flow_or_workflow
    |> result_workflow()
    |> Workflow.event_log()
  end

  defp do_summary(%Result{workflow: workflow, status: status, cycles: cycles, error: error}) do
    workflow
    |> do_summary()
    |> Map.merge(%{status: status, cycles: cycles, error: error})
  end

  defp do_summary(flow_or_workflow) do
    workflow = result_workflow(flow_or_workflow)

    %{
      total_nodes: workflow |> Workflow.components() |> map_size(),
      facts_produced: workflow |> Workflow.facts() |> length(),
      satisfied?: not Workflow.is_runnable?(workflow),
      productions: workflow |> Workflow.raw_productions() |> length()
    }
  end

  defp do_provenance(%Result{workflow: workflow}, fact_hash),
    do: do_provenance(workflow, fact_hash)

  defp do_provenance(flow_or_workflow, fact_hash) do
    facts =
      flow_or_workflow
      |> result_workflow()
      |> Workflow.facts()
      |> Map.new(&{&1.hash, &1})

    case Map.fetch(facts, fact_hash) do
      {:ok, fact} -> {:ok, build_provenance_chain(fact, facts, [])}
      :error -> {:error, :not_found}
    end
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

  defp result_workflow(%Workflow{} = workflow), do: workflow

  defp one_step_flow(%Instruction{} = instruction, name) do
    {:ok, Flow.from_action(instruction, %{}, one_step_name_opts(name))}
  rescue
    error in [ArgumentError] ->
      {:error, Error.validation_error(Exception.message(error), %{value: instruction})}
  end

  defp one_step_flow(action, params, name) when is_atom(action) and not is_nil(action) do
    {:ok, Flow.from_action(action, params, one_step_name_opts(name))}
  rescue
    error in [ArgumentError] ->
      {:error, Error.validation_error(Exception.message(error), %{value: action})}
  end

  defp one_step_name_opts(nil), do: []
  defp one_step_name_opts(name), do: [name: name]

  defp validate_direct_action_contract(action) do
    case Instruction.validate_action_contract(action) do
      :ok ->
        :ok

      {:error, error} ->
        {:error, error}
    end
  end

  defp one_step_input(@no_input), do: %{}
  defp one_step_input(nil), do: %{}
  defp one_step_input(input), do: input

  defp unsupported_executable(value) do
    {:error,
     Error.validation_error(
       "expected a Jido.Action module, Jido.Instruction, or Jido.Flow",
       %{value: value}
     )}
  end

  defp unsupported_result(value) do
    {:error,
     Error.validation_error(
       "expected a Jido.Exec.Result",
       %{value: value}
     )}
  end
end
