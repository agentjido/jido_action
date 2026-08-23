defmodule Jido.Flow.Compiler.Map do
  @moduledoc false

  alias Jido.Action.Error
  alias Jido.Flow.Compiler.ErrorTagger
  alias Jido.Flow.Compiler.Expression
  alias Jido.Flow.Compiler.Target
  alias Jido.Flow.Identity
  alias Jido.Flow.Map, as: FlowMap

  @doc false
  def run(map, collection, state) do
    if is_list(collection) and not List.improper?(collection) do
      items =
        collection
        |> Enum.with_index()
        |> Enum.map(fn {item, index} ->
          %{
            item: item,
            item_index: index,
            item_id: Identity.item_uuid(state.flow_digest, map.name, index)
          }
        end)

      case dispatch_map_items(map, items, state) do
        {:ok, results, errors} ->
          aggregate = %{kind: :jido_flow_map_result, results: results, errors: errors}
          {:ok, aggregate}

        {:error, error, _started_count, _success_count, _error_count} ->
          {:error, error, state}
      end
    else
      error =
        Error.execution_error("map collection must resolve to a proper list", %{
          phase: :map_collection,
          node: map.name,
          reason: :not_a_proper_list,
          value_type: Expression.value_type(collection),
          retry: false
        })

      {:error, error, state}
    end
  end

  defp dispatch_map_items(%FlowMap{on_error: :fail_fast} = map, items, state) do
    window_size = map_window_size(state.options)

    items
    |> Stream.chunk_every(window_size)
    |> Enum.reduce_while({:ok, [], 0, 0}, fn window,
                                             {:ok, result_chunks, success_before, started_before} ->
      outcomes = dispatch_map_window(map, window, state)
      successes = for {:ok, result} <- outcomes, do: result
      failures = for {:error, failure} <- outcomes, do: failure
      started_count = started_before + length(window)

      case failures do
        [] ->
          {:cont,
           {:ok, [successes | result_chunks], success_before + length(successes), started_count}}

        failures ->
          selected = Enum.min_by(failures, & &1.index)

          {:halt,
           {:error, selected.error, started_count, success_before + length(successes),
            length(failures)}}
      end
    end)
    |> case do
      {:ok, result_chunks, _success_count, _started_count} ->
        {:ok, result_chunks |> Enum.reverse() |> List.flatten(), []}

      {:error, error, started_count, success_count, error_count} ->
        {:error, error, started_count, success_count, error_count}
    end
  end

  defp dispatch_map_items(%FlowMap{on_error: :collect_errors}, [], _state),
    do: {:ok, [], []}

  defp dispatch_map_items(%FlowMap{on_error: :collect_errors} = map, items, state) do
    outcomes = dispatch_map_window(map, items, state)

    results = for {:ok, result} <- outcomes, do: result
    errors = for {:error, error} <- outcomes, do: error
    {:ok, results, errors}
  end

  defp dispatch_map_window(map, items, state) do
    if Keyword.fetch!(state.options, :async) do
      execute_async_map_items(map, items, state)
    else
      Enum.map(items, &run_map_item(map, &1, state))
    end
  end

  defp execute_async_map_items(map, items, state) do
    caller = self()
    reference = make_ref()

    {worker, monitor} =
      spawn_monitor(fn ->
        worker = self()
        spawn(fn -> terminate_map_worker_with_caller(caller, worker) end)
        Process.flag(:trap_exit, true)

        outcomes =
          items
          |> Task.async_stream(&run_map_item(map, &1, state),
            max_concurrency: Keyword.fetch!(state.options, :max_concurrency),
            timeout: :infinity,
            ordered: true
          )
          |> Stream.zip(items)
          |> Enum.map(fn
            {{:ok, outcome}, _item_state} ->
              outcome

            {{:exit, reason}, item_state} ->
              map_item_task_exit(map, item_state, reason)
          end)

        send(caller, {reference, self(), outcomes})
      end)

    receive do
      {^reference, ^worker, outcomes} ->
        Process.demonitor(monitor, [:flush])
        outcomes

      {:DOWN, ^monitor, :process, ^worker, reason} ->
        exit(reason)
    end
  end

  defp terminate_map_worker_with_caller(caller, worker) do
    caller_monitor = Process.monitor(caller)
    worker_monitor = Process.monitor(worker)

    receive do
      {:DOWN, ^caller_monitor, :process, ^caller, _reason} -> Process.exit(worker, :kill)
      {:DOWN, ^worker_monitor, :process, ^worker, _reason} -> :ok
    end
  end

  defp run_map_item(map, item_state, state) do
    local_state = Map.merge(state, item_state)

    with {:ok, params} <- resolve_map_input(map, local_state, item_state),
         {:ok, output} <-
           Target.run(
             map.action,
             params,
             state.context,
             ErrorTagger.map_target_owner(map, item_state),
             state.execution_id,
             state.target_runner
           ) do
      {:ok, %{item_id: item_state.item_id, index: item_state.item_index, output: output}}
    else
      {:error, error} ->
        {:error, %{item_id: item_state.item_id, index: item_state.item_index, error: error}}
    end
  end

  defp resolve_map_input(map, state, item_state) do
    map.input
    |> Expression.resolve(state)
    |> ErrorTagger.tag_target_validation_error(
      :input,
      ErrorTagger.map_target_owner(map, item_state)
    )
  end

  defp map_item_task_exit(map, item_state, reason) do
    error =
      Error.execution_error("flow map item task exited", %{
        phase: :map_target_execution,
        node: map.name,
        target: map.action,
        item_index: item_state.item_index,
        item_id: item_state.item_id,
        reason: reason
      })

    {:error, %{item_id: item_state.item_id, index: item_state.item_index, error: error}}
  end

  defp map_window_size(options) do
    if Keyword.fetch!(options, :async) do
      Keyword.fetch!(options, :max_concurrency)
    else
      1
    end
  end
end
