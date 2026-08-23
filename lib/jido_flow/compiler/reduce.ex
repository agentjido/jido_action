defmodule Jido.Flow.Compiler.Reduce do
  @moduledoc false

  alias Jido.Action.Error
  alias Jido.Action.Output
  alias Jido.Flow.Compiler.ErrorTagger
  alias Jido.Flow.Compiler.Expression
  alias Jido.Flow.Compiler.Target
  alias Jido.Flow.Identity
  alias Jido.Flow.Ref

  @doc false
  def run(reduce, collection, state) do
    with {:ok, items} <- normalize_reduce_collection(reduce, collection, state),
         {:ok, initial} <- Expression.resolve(reduce.initial, state),
         {:ok, initial} <- validate_reduce_initial(reduce, initial) do
      fold_reduce_items(reduce, items, initial, state)
    else
      {:error, error} -> {:error, error, state}
    end
  end

  defp normalize_reduce_collection(reduce, collection, state) do
    if direct_map_source?(reduce.collection, state.map_nodes) do
      normalize_direct_map_result(reduce, collection)
    else
      normalize_reduce_list(reduce, collection, state.flow_digest)
    end
  end

  defp direct_map_source?(%Ref{type: :result, node: node, path: []}, map_nodes) do
    MapSet.member?(map_nodes, node)
  end

  defp direct_map_source?(_collection, _map_nodes), do: false

  defp normalize_reduce_list(reduce, collection, flow_digest) do
    if is_list(collection) and not List.improper?(collection) do
      items =
        collection
        |> Enum.with_index()
        |> Enum.map(fn {item, index} ->
          %{
            item: item,
            item_index: index,
            item_id: Identity.item_uuid(flow_digest, reduce.name, index)
          }
        end)

      {:ok, items}
    else
      {:error,
       Error.execution_error("reduce collection must resolve to a proper list", %{
         phase: :reduce_collection,
         node: reduce.name,
         reason: :not_a_proper_list,
         value_type: Expression.value_type(collection),
         retry: false
       })}
    end
  end

  defp normalize_direct_map_result(
         reduce,
         %{kind: :jido_flow_map_result, results: results, errors: errors} = aggregate
       ) do
    with :ok <- validate_direct_map_keys(aggregate),
         :ok <- validate_direct_map_records(results, errors) do
      if errors == [] do
        {:ok,
         Enum.map(results, fn result ->
           %{item: result.output, item_index: result.index, item_id: result.item_id}
         end)}
      else
        {:error,
         Error.execution_error("reduce cannot consume a Map result with errors", %{
           phase: :reduce_collection,
           node: reduce.name,
           reason: :map_errors_present,
           error_indices: Enum.map(errors, & &1.index),
           retry: false
         })}
      end
    else
      {:error, path} -> invalid_direct_map_result(reduce, path)
    end
  end

  defp normalize_direct_map_result(reduce, _collection),
    do: invalid_direct_map_result(reduce, [])

  defp validate_direct_map_keys(aggregate) do
    if aggregate |> Map.keys() |> MapSet.new() ==
         MapSet.new([:kind, :results, :errors]) do
      :ok
    else
      {:error, []}
    end
  end

  defp validate_direct_map_records(results, errors) do
    with true <- is_list(results) and not List.improper?(results),
         true <- is_list(errors) and not List.improper?(errors),
         :ok <- validate_direct_records(results, :result, [:results]),
         :ok <- validate_direct_records(errors, :error, [:errors]),
         :ok <- validate_direct_record_identity(results, errors) do
      :ok
    else
      false -> {:error, []}
      {:error, path} -> {:error, path}
    end
  end

  defp validate_direct_records(records, kind, root_path) do
    records
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, -1}, fn {record, position}, {:ok, previous_index} ->
      case validate_direct_record(record, kind, previous_index) do
        {:ok, index} -> {:cont, {:ok, index}}
        :error -> {:halt, {:error, root_path ++ [position]}}
      end
    end)
    |> case do
      {:ok, _last_index} -> :ok
      {:error, path} -> {:error, path}
    end
  end

  defp validate_direct_record(record, kind, previous_index) when is_map(record) do
    index = Map.get(record, :index)

    if valid_direct_record_keys?(record, kind) and valid_direct_record_value?(record, kind) and
         is_integer(index) and index >= 0 and index > previous_index and
         is_binary(Map.get(record, :item_id)) do
      {:ok, index}
    else
      :error
    end
  end

  defp validate_direct_record(_record, _kind, _previous_index), do: :error

  defp valid_direct_record_keys?(record, :result),
    do: MapSet.new(Map.keys(record)) == MapSet.new([:item_id, :index, :output])

  defp valid_direct_record_keys?(record, :error),
    do: MapSet.new(Map.keys(record)) == MapSet.new([:item_id, :index, :error])

  defp valid_direct_record_value?(record, :result),
    do: valid_reduce_accumulator?(Map.get(record, :output))

  defp valid_direct_record_value?(record, :error),
    do: is_exception(Map.get(record, :error))

  defp validate_direct_record_identity(results, errors) do
    records = results ++ errors
    indexes = Enum.map(records, & &1.index)
    item_ids = Enum.map(records, & &1.item_id)

    if length(Enum.uniq(indexes)) == length(indexes) and
         length(Enum.uniq(item_ids)) == length(item_ids) do
      :ok
    else
      {:error, []}
    end
  end

  defp invalid_direct_map_result(reduce, path) do
    {:error,
     Error.execution_error("reduce received an invalid Map result", %{
       phase: :reduce_collection,
       node: reduce.name,
       reason: :invalid_map_result,
       retry: false,
       path: path
     })}
  end

  defp validate_reduce_initial(reduce, initial) do
    if valid_reduce_accumulator?(initial) do
      {:ok, initial}
    else
      {:error,
       Error.execution_error("reduce initial value must be a map or Jido.Action.Output", %{
         phase: :reduce_initial,
         node: reduce.name,
         reason: :output_envelope_required,
         value_type: Expression.value_type(initial),
         retry: false
       })}
    end
  end

  defp valid_reduce_accumulator?(%Output{} = output),
    do: match?({:ok, _}, Output.validate(output))

  defp valid_reduce_accumulator?(value), do: is_map(value)

  defp fold_reduce_items(reduce, items, initial, state) do
    items
    |> Enum.reduce_while({:ok, initial, 0}, fn item_state, {:ok, accumulator, completed} ->
      case run_reduce_item(reduce, item_state, accumulator, state) do
        {:ok, next_accumulator} -> {:cont, {:ok, next_accumulator, completed + 1}}
        {:error, error} -> {:halt, {:error, error, completed + 1, completed}}
      end
    end)
    |> case do
      {:ok, accumulator, _completed_count} ->
        {:ok, accumulator}

      {:error, error, _item_count, _completed_count} ->
        {:error, error, state}
    end
  end

  defp run_reduce_item(reduce, item_state, accumulator, state) do
    local_state =
      state
      |> Map.merge(item_state)
      |> Map.put(:accumulator, accumulator)

    with {:ok, params} <- resolve_reduce_input(reduce, local_state, item_state) do
      Target.run(
        reduce.action,
        params,
        state.context,
        ErrorTagger.reduce_target_owner(reduce, item_state),
        state.execution_id,
        state.target_runner
      )
    end
  end

  defp resolve_reduce_input(reduce, state, item_state) do
    reduce.input
    |> Expression.resolve(state)
    |> ErrorTagger.tag_target_validation_error(
      :input,
      ErrorTagger.reduce_target_owner(reduce, item_state)
    )
  end
end
