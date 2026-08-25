defmodule Jido.Flow.Compiler.Reduce do
  @moduledoc false

  alias Jido.Action.Error
  alias Jido.Action.Output
  alias Jido.Flow.Compiler.ErrorTagger
  alias Jido.Flow.Compiler.Expression
  alias Jido.Flow.Compiler.MapResult
  alias Jido.Flow.Compiler.Target
  alias Jido.Flow.Compiler.TargetContext
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

  defp direct_map_source?(%Ref{source: :result, component: component, path: []}, map_nodes) do
    MapSet.member?(map_nodes, component)
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

  defp normalize_direct_map_result(reduce, aggregate) do
    case MapResult.validate(aggregate) do
      {:ok, results, []} ->
        {:ok,
         Enum.map(results, fn result ->
           %{item: result.output, item_index: result.index, item_id: result.item_id}
         end)}

      {:ok, _results, errors} ->
        {:error,
         Error.execution_error("reduce cannot consume a Map result with errors", %{
           phase: :reduce_collection,
           node: reduce.name,
           reason: :map_errors_present,
           error_indices: Enum.map(errors, & &1.index),
           retry: false
         })}

      {:error, path} ->
        invalid_direct_map_result(reduce, path)
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

    target_context = TargetContext.reduce(reduce, item_state)

    span =
      state.observer.({
        :start,
        :reduce_item,
        %{
          node: reduce.name,
          target: reduce.action,
          item_index: item_state.item_index,
          item_id: item_state.item_id
        }
      })

    result =
      with {:ok, params} <- resolve_reduce_input(reduce, local_state, target_context) do
        Target.run(
          reduce.action,
          params,
          state.context,
          target_context,
          state.execution_id,
          state.target_runner
        )
      end

    finish_item_span(state.observer, span, result)
    result
  end

  defp resolve_reduce_input(reduce, state, target_context) do
    reduce.params
    |> Expression.resolve(state)
    |> ErrorTagger.tag_target_validation_error(:input, target_context)
  end

  defp finish_item_span(observer, span, {:ok, _result}), do: observer.({:stop, span})
  defp finish_item_span(observer, span, {:error, error}), do: observer.({:error, span, error})
end
