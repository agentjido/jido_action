defmodule Jido.Flow.Compiler.Expression do
  @moduledoc false

  alias Jido.Action.Error
  alias Jido.Action.Output
  alias Jido.Flow.Ref

  @doc false
  def resolve(%Ref{source: :input} = ref, state), do: resolve_path(ref, state.input)

  def resolve(%Ref{source: :context} = ref, state), do: resolve_path(ref, state.context)

  def resolve(%Ref{source: :result, component: component} = ref, state) do
    case Map.fetch(state.results, component) do
      {:ok, result} -> resolve_path(ref, result)
      :error -> missing_source(ref)
    end
  end

  def resolve(%Ref{source: :item} = ref, state), do: resolve_state_path(ref, state, :item)

  def resolve(%Ref{source: :item_index}, state), do: {:ok, Map.get(state, :item_index)}
  def resolve(%Ref{source: :item_id}, state), do: {:ok, Map.get(state, :item_id)}

  def resolve(%Ref{source: :accumulator} = ref, state),
    do: resolve_state_path(ref, state, :accumulator)

  def resolve(%Ref{source: :state} = ref, state),
    do: resolve_state_path(ref, state, :iterate_state)

  def resolve(%Ref{source: :iteration_index}, state) do
    {:ok, Map.get(state, :iteration_index)}
  end

  def resolve(%Ref{source: :body_result} = ref, state),
    do: resolve_state_path(ref, state, :body_result)

  def resolve(%Ref{source: source}, _state) do
    {:error,
     Error.validation_error("unsupported flow ref source: #{inspect(source)}", %{source: source})}
  end

  def resolve(%{} = map, state) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case resolve(value, state) do
        {:ok, resolved} -> {:cont, {:ok, Map.put(acc, key, resolved)}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  def resolve(list, state) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn value, {:ok, acc} ->
      case resolve(value, state) do
        {:ok, resolved} -> {:cont, {:ok, [resolved | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, error} -> {:error, error}
    end
  end

  def resolve(value, _state), do: {:ok, value}

  @doc false
  def value_type(nil), do: nil
  def value_type(%Output{}), do: :action_output
  def value_type(value) when is_list(value), do: :list
  def value_type(value) when is_map(value), do: :map
  def value_type(value) when is_binary(value), do: :binary
  def value_type(value) when is_number(value), do: :number
  def value_type(value) when is_atom(value), do: :atom
  def value_type(value) when is_tuple(value), do: :tuple
  def value_type(_value), do: :other

  defp resolve_state_path(ref, state, key) do
    case Map.fetch(state, key) do
      {:ok, value} -> resolve_path(ref, value)
      :error -> missing_source(ref)
    end
  end

  defp resolve_path(%Ref{path: path} = ref, value) do
    case fetch_path(value, path, []) do
      {:ok, resolved} ->
        {:ok, resolved}

      {:error, details} ->
        {:error,
         Error.execution_error(
           "flow reference path does not exist",
           ref
           |> ref_details()
           |> Map.merge(details)
           |> Map.merge(%{path: path, retry: false})
         )}
    end
  end

  defp missing_source(ref) do
    {:error,
     Error.execution_error(
       "flow reference source is not available",
       ref
       |> ref_details()
       |> Map.merge(%{path: ref.path, reason: :source_not_available, retry: false})
     )}
  end

  defp ref_details(%Ref{source: :result, component: component}),
    do: %{ref_type: :result, node: component}

  defp ref_details(%Ref{source: source}), do: %{ref_type: source}

  defp fetch_path(value, [], _resolved_path_rev), do: {:ok, value}

  defp fetch_path(value, [key | rest], resolved_path_rev) when is_map(value) do
    case fetch_key(value, key) do
      {:ok, nested} ->
        fetch_path(nested, rest, [key | resolved_path_rev])

      :error ->
        path_error(:missing_key, key, resolved_path_rev, value)
    end
  end

  defp fetch_path(value, [key | rest], resolved_path_rev)
       when is_list(value) and is_integer(key) and key >= 0 do
    case list_at(value, key) do
      {:ok, nested} ->
        fetch_path(nested, rest, [key | resolved_path_rev])

      :error ->
        path_error(:missing_index, key, resolved_path_rev, value)
    end
  end

  defp fetch_path(value, [key | _rest], resolved_path_rev) do
    path_error(:not_traversable, key, resolved_path_rev, value)
  end

  defp list_at([head | _tail], 0), do: {:ok, head}
  defp list_at([_head | tail], index), do: list_at(tail, index - 1)
  defp list_at(_tail, _index), do: :error

  defp fetch_key(map, key) do
    cond do
      Map.has_key?(map, key) ->
        Map.fetch(map, key)

      is_atom(key) and Map.has_key?(map, Atom.to_string(key)) ->
        Map.fetch(map, Atom.to_string(key))

      true ->
        :error
    end
  end

  defp path_error(reason, segment, resolved_path_rev, value) do
    {:error,
     %{
       reason: reason,
       segment: segment,
       resolved_path: Enum.reverse(resolved_path_rev),
       value_type: value_type(value)
     }}
  end
end
