defmodule Jido.Exec.Flow.RunnableExecutor do
  @moduledoc false

  alias Jido.Exec.Execution
  alias Jido.Exec.Telemetry
  alias Jido.Exec.Worker
  alias Jido.Flow.Error
  alias Runic.Workflow
  alias Runic.Workflow.FanIn
  alias Runic.Workflow.Runnable

  @doc "Executes one native Runnable and records its node telemetry."
  @spec execute(Execution.t(), Runnable.t()) :: Runnable.t()
  def execute(%Execution{} = execution, %Runnable{} = runnable) do
    execute_with_metadata(runnable, node_metadata(execution, runnable))
  end

  defp execute_with_metadata(runnable, metadata) do
    span = start_span(metadata)
    executed = safely_execute(runnable)
    finish_span(span, executed)
    compact_coordination_context(executed)
  end

  # Runic prepares every FanIn item with a copy of the whole sibling set.
  # The apply phase reads only these keys, so do not send the sibling set back
  # from every worker in a large Map wave.
  defp compact_coordination_context(
         %Runnable{
           node: %FanIn{},
           context: %{fan_in_context: %{mode: :fan_out_reduce} = fan_in_context} = context
         } = runnable
       ) do
    needed = Map.take(fan_in_context, [:mode, :source_fact_hash, :expected_key, :seen_key])
    %{runnable | context: %{context | fan_in_context: needed}}
  end

  defp compact_coordination_context(runnable), do: runnable

  @doc "Executes native Runnables and returns the admitted input prefix in source order."
  @spec execute_many(Execution.t(), [Runnable.t()]) :: [Runnable.t()]
  def execute_many(%Execution{} = execution, runnables) when is_list(runnables) do
    if coordination_only?(runnables) do
      execute_serially(execution, runnables)
    else
      if Keyword.fetch!(execution.options, :max_concurrency) > 1 and match?([_, _ | _], runnables) do
        execute_concurrently(execution, runnables)
      else
        execute_serially(execution, runnables)
      end
    end
  end

  # FanIn coordination does not run an Action. Its prepared context can carry
  # the full sibling set. Keep it in one process instead of copying it to a
  # separate Task for every item in a large Map.
  defp coordination_only?(runnables) do
    runnables != [] and
      Enum.all?(runnables, fn
        %Runnable{node: %FanIn{}, context: %{fan_in_context: %{mode: :fan_out_reduce}}} ->
          true

        _ ->
          false
      end)
  end

  defp execute_serially(execution, runnables) do
    runnables
    |> Enum.reduce_while([], fn runnable, completed ->
      executed = execute(execution, runnable)
      completed = [executed | completed]

      if executed.status == :failed, do: {:halt, completed}, else: {:cont, completed}
    end)
    |> Enum.reverse()
  end

  defp execute_concurrently(execution, runnables) do
    ref = :erlang.alias()
    telemetry_tracker = Telemetry.tracker() || ref
    stopped = :atomics.new(1, [])

    execute = fn {runnable, index, metadata} ->
      Telemetry.put_tracker(telemetry_tracker)
      executed = execute_with_metadata(runnable, metadata)
      if executed.status == :failed, do: :atomics.put(stopped, 1, 1)
      {index, executed}
    end

    state = %{
      ref: ref,
      tracker: telemetry_tracker,
      spans: %{},
      supervisor: Keyword.fetch!(execution.options, :task_supervisor),
      limit: Keyword.fetch!(execution.options, :max_concurrency),
      pending: Enum.with_index(runnables),
      active: %{},
      completed: [],
      stopped: stopped,
      execute: execute,
      metadata: &node_metadata(execution, &1)
    }

    try do
      state
      |> collect()
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))
    after
      :erlang.unalias(ref)
      Telemetry.drain(ref, %{})
      flush_results(ref)
    end
  end

  defp collect(state) do
    case advance(state) do
      {:done, completed} -> completed
      next -> collect(next)
    end
  end

  defp advance(state) do
    cond do
      state.pending != [] and map_size(state.active) < state.limit and
          :atomics.get(state.stopped, 1) == 0 ->
        dispatch(state)

      map_size(state.active) == 0 ->
        Telemetry.drain(state.ref, state.spans)
        {:done, state.completed}

      true ->
        receive_result(state)
    end
  catch
    kind, reason ->
      # Each iteration owns its current active map. Clean up before an error
      # leaves this frame; no external registry or retained loop frames are needed.
      stop_active(state.active)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp dispatch(%{pending: [{runnable, index} | rest]} = state) do
    # Do not copy the Execution, sibling runnables, or completed results into workers.
    work = worker(state.execute, {runnable, index, state.metadata.(runnable)})

    case Worker.start(state.supervisor, state.ref, work) do
      {:ok, pid, monitor} ->
        %{state | pending: rest, active: Map.put(state.active, pid, {monitor, runnable, index})}

      {:error, reason} ->
        :atomics.put(state.stopped, 1, 1)
        failed = fail_exited_runnable(runnable, {:start_error, reason})
        %{state | pending: [], completed: [{index, failed} | state.completed]}
    end
  end

  defp worker(execute, input), do: fn -> execute.(input) end

  defp receive_result(%{ref: ref} = state) do
    active = state.active

    receive do
      {^ref, :telemetry, event} ->
        %{state | spans: Telemetry.record(state.spans, event)}

      {^ref, :worker_error, worker, error} ->
        %{state | spans: Telemetry.fail(Telemetry.drain(ref, state.spans), error, worker)}

      {^ref, pid, indexed_result} when is_map_key(active, pid) ->
        {monitor, _runnable, _index} = Map.fetch!(active, pid)
        Worker.finish(pid, monitor)

        %{state | active: Map.delete(active, pid), completed: [indexed_result | state.completed]}

      {:DOWN, monitor, :process, pid, reason} when is_map_key(active, pid) ->
        {^monitor, runnable, index} = Map.fetch!(active, pid)
        :atomics.put(state.stopped, 1, 1)
        failed = fail_exited_runnable(runnable, reason)

        spans =
          if state.tracker == ref do
            Telemetry.fail(Telemetry.drain(ref, state.spans), failed.error, pid)
          else
            Telemetry.fail_worker(state.tracker, pid, failed.error)
            state.spans
          end

        %{
          state
          | spans: spans,
            active: Map.delete(active, pid),
            pending: [],
            completed: [{index, failed} | state.completed]
        }
    end
  end

  defp stop_active(active),
    do: Worker.terminate(for {pid, {monitor, _, _}} <- active, do: {pid, monitor})

  defp flush_results(ref) do
    receive do
      {^ref, _worker, _result} -> flush_results(ref)
    after
      0 -> :ok
    end
  end

  defp safely_execute(runnable) do
    Workflow.execute_runnable(runnable)
  rescue
    error -> Runnable.fail(runnable, error)
  catch
    kind, reason ->
      Runnable.fail(
        runnable,
        Error.execution_error("flow runnable #{kind}", %{
          runnable_id: runnable.id,
          node: runnable_name(runnable),
          reason: reason
        })
      )
  end

  defp start_span(nil), do: nil
  defp start_span(metadata), do: Telemetry.start([:jido, :flow, :node], metadata)

  defp node_metadata(execution, runnable) do
    case authored_component(execution, runnable) do
      {name, kind} ->
        %{
          execution_id: execution.id,
          flow: execution.flow_name,
          node: name,
          kind: kind
        }

      nil ->
        nil
    end
  end

  defp finish_span(nil, _runnable), do: :ok
  defp finish_span(span, %Runnable{status: :completed}), do: Telemetry.stop(span)
  defp finish_span(span, %Runnable{status: :skipped}), do: Telemetry.stop(span)

  defp finish_span(span, %Runnable{status: :failed, error: error}) do
    Telemetry.error(span, normalize_error(error))
  end

  defp finish_span(span, %Runnable{status: status}) do
    Telemetry.error(span, Error.execution_error("unsupported runnable status", %{status: status}))
  end

  defp authored_component(execution, %Runnable{node: %{name: runnable_name, hash: hash}}) do
    with %{component_path: [name]} <- Map.get(execution.compiled.work_index, hash),
         %{output: ^runnable_name, kind: kind} <-
           Map.get(execution.compiled.component_index, name) do
      {name, kind}
    else
      _ -> nil
    end
  end

  defp authored_component(_execution, _runnable), do: nil

  defp fail_exited_runnable(runnable, reason) do
    Runnable.fail(
      runnable,
      Error.execution_error("flow runnable task exited", %{
        runnable_id: runnable.id,
        node: runnable_name(runnable),
        node_path: [runnable_name(runnable)],
        reason: reason
      })
    )
  end

  defp runnable_name(%Runnable{node: %{name: name}}), do: name
  defp runnable_name(%Runnable{node: node}), do: node.__struct__

  defp normalize_error(error) when is_exception(error), do: error

  defp normalize_error(reason),
    do: Error.execution_error("flow runnable failed", %{reason: reason})
end
