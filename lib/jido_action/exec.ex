defmodule Jido.Exec do
  @moduledoc """
  Runic-backed execution facade for Jido flows.

  `Jido.Exec` accepts `Jido.Flow` and raw `Runic.Workflow` values only. Direct
  action execution is intentionally not a runtime concern here; actions are leaf
  components invoked by `Jido.Flow.Step` while retry, timeout, fallback,
  scheduling, and durable execution are owned by Runic.
  """

  alias Jido.Action.Error
  alias Jido.Exec.Result
  alias Jido.Flow
  alias Runic.Workflow
  alias Runic.Workflow.{Fact, PolicyDriver, Runnable, SchedulerPolicy}

  @no_input {__MODULE__, :no_input}

  @type executable :: Flow.t() | Workflow.t()
  @type run_opts :: keyword()

  @doc """
  Executes a flow or Runic workflow to quiescence.

  Runtime execution options are Runic workflow options. Use `run/3` with an
  explicit input when input is present. Use `:run_context` for
  runtime context and `:scheduler_policies` for runtime policy overrides.
  """
  @spec run(executable()) :: {:ok, Result.t()} | {:error, Result.t()} | {:error, Exception.t()}
  def run(%Flow{} = flow), do: run_workflow(flow, @no_input, [])
  def run(%Workflow{} = workflow), do: run_workflow(workflow, @no_input, [])
  def run(other), do: unsupported_executable(other)

  @spec run(executable(), term()) ::
          {:ok, Result.t()} | {:error, Result.t()} | {:error, Exception.t()}
  def run(%Flow{} = flow, input), do: run_workflow(flow, input, [])
  def run(%Workflow{} = workflow, input), do: run_workflow(workflow, input, [])
  def run(other, _input), do: unsupported_executable(other)

  @spec run(executable(), term(), run_opts()) ::
          {:ok, Result.t()} | {:error, Result.t()} | {:error, Exception.t()}
  def run(%Flow{} = flow, input, opts) when is_list(opts),
    do: run_workflow(flow, input, opts)

  def run(%Workflow{} = workflow, input, opts) when is_list(opts),
    do: run_workflow(workflow, input, opts)

  def run(other, _input, _opts), do: unsupported_executable(other)

  @doc """
  Performs one Runic prepare/dispatch/apply cycle.
  """
  @spec step(Flow.t() | Workflow.t()) ::
          {:ok, Result.t()} | {:error, Result.t()} | {:error, Exception.t()}
  def step(flow_or_workflow), do: step_workflow(flow_or_workflow, @no_input, [])

  @spec step(Flow.t() | Workflow.t(), term(), keyword()) ::
          {:ok, Result.t()} | {:error, Result.t()} | {:error, Exception.t()}
  def step(flow_or_workflow, input, opts) when is_list(opts) do
    step_workflow(flow_or_workflow, input, opts)
  end

  @doc """
  Continues a local flow or workflow with new input and runs it to quiescence.
  """
  @spec resume(Flow.t() | Workflow.t(), term(), keyword()) ::
          {:ok, Result.t()} | {:error, Result.t()} | {:error, Exception.t()}
  def resume(flow_or_workflow, input), do: resume(flow_or_workflow, input, [])

  def resume(flow_or_workflow, input, opts) when is_list(opts) do
    run_workflow(flow_or_workflow, input, opts)
  end

  @doc """
  Returns runtime results from a result, flow, or raw Runic workflow.
  """
  @spec results(Result.t() | Flow.t() | Workflow.t(), keyword()) :: term()
  def results(result_or_workflow), do: results(result_or_workflow, [])

  def results(result_or_workflow, opts) when is_list(opts) do
    do_results(result_or_workflow, opts)
  end

  @doc """
  Returns durable and in-memory events associated with a result or workflow.
  """
  @spec events(Result.t() | Flow.t() | Workflow.t(), keyword()) :: [term()]
  def events(result_or_workflow, opts \\ []) do
    do_events(result_or_workflow, opts)
  end

  @doc """
  Returns a compact execution summary for a result, flow, or workflow.
  """
  @spec summary(Result.t() | Flow.t() | Workflow.t()) :: map()
  def summary(result_or_workflow), do: do_summary(result_or_workflow)

  @doc """
  Walks a produced fact's ancestry through the workflow.
  """
  @spec provenance(Result.t() | Flow.t() | Workflow.t(), term()) ::
          {:ok, [Runic.Workflow.Fact.t()]} | {:error, :not_found}
  def provenance(result_or_workflow, fact_hash) do
    do_provenance(result_or_workflow, fact_hash)
  end

  defp run_workflow(flow_or_workflow, input, opts) do
    with {:ok, workflow} <- normalize_workflow(flow_or_workflow),
         :ok <- validate_run_context(Keyword.get(opts, :run_context)),
         :ok <- validate_max_cycles(Keyword.get(opts, :max_cycles, :infinity)) do
      workflow
      |> start_workflow(input, opts)
      |> continue_workflow(opts, 0)
    end
  end

  defp step_workflow(flow_or_workflow, input, opts) do
    with {:ok, workflow} <- normalize_workflow(flow_or_workflow),
         :ok <- validate_run_context(Keyword.get(opts, :run_context)) do
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
      nil -> workflow
      context when is_map(context) -> Workflow.put_run_context(workflow, context)
    end
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
        {executed, runnable_events} = execute_runnable(runnable, policies, driver_opts)

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

  defp execute_runnable(%Runnable{} = runnable, policies, driver_opts) do
    policy = SchedulerPolicy.resolve(runnable, policies)
    driver_opts = Keyword.put(driver_opts, :emit_events, true)

    runnable
    |> execute_runnable_in_worker(policy, driver_opts)
    |> normalize_worker_result(runnable)
  end

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
    case Process.whereis(Jido.Action.TaskSupervisor) do
      nil -> Task.start(work)
      _pid -> Task.Supervisor.start_child(Jido.Action.TaskSupervisor, work)
    end
  end

  defp run_policy_driver(%Runnable{} = runnable, %SchedulerPolicy{} = policy, driver_opts) do
    trap_exit? = Process.flag(:trap_exit, true)

    try do
      {:ok, PolicyDriver.execute(runnable, policy, driver_opts)}
    rescue
      error in [CaseClauseError] ->
        case error.term do
          {:exit, reason} ->
            {:error,
             Error.execution_error("runnable execution exited", %{kind: :exit, reason: reason})}

          _other ->
            {:error,
             Error.execution_error("runnable execution raised", %{
               reason: error,
               stacktrace: __STACKTRACE__
             })}
        end

      error ->
        {:error,
         Error.execution_error("runnable execution raised", %{
           reason: error,
           stacktrace: __STACKTRACE__
         })}
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

  defp normalize_worker_result({:ok, %Runnable{} = runnable}, _original), do: {runnable, []}

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

  defp normalize_scheduler_policy(policy), do: policy

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

  defp normalize_workflow(%Flow{} = flow), do: {:ok, Flow.to_workflow(flow)}
  defp normalize_workflow(%Workflow{} = workflow), do: {:ok, workflow}
  defp normalize_workflow(other), do: unsupported_executable(other)

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

  defp do_results(%Result{results: results}, []), do: results
  defp do_results(%Result{workflow: workflow}, opts), do: do_results(workflow, opts)

  defp do_results(flow_or_workflow, opts) when is_list(opts) do
    workflow = result_workflow(flow_or_workflow)
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

  defp do_events(%Result{events: events}, []), do: events
  defp do_events(%Result{workflow: workflow}, opts), do: do_events(workflow, opts)

  defp do_events(flow_or_workflow, _opts) do
    flow_or_workflow
    |> result_workflow()
    |> Workflow.event_log()
  rescue
    _ -> []
  catch
    _, _ -> []
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

  defp result_workflow(%Flow{} = flow), do: Flow.to_workflow(flow)
  defp result_workflow(%Workflow{} = workflow), do: workflow

  defp unsupported_executable(value) do
    {:error,
     Error.validation_error(
       "expected a Jido.Flow or Runic.Workflow",
       %{value: value}
     )}
  end
end
