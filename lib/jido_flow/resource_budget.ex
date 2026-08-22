defmodule Jido.Flow.ResourceBudget do
  @moduledoc false

  alias Jido.Action.Error

  @max_depth 64
  @max_term_slots 100_000
  @max_binary_bytes 1_048_576
  @max_width 10_000

  @type surface :: :map

  @spec validate(term(), surface()) :: :ok | {:error, Exception.t()}
  def validate(term, :map) do
    traverse([{term, 0, []}], %{term_count: 0, binary_bytes: 0}, :map)
  end

  defp traverse([], _counts, _surface), do: :ok

  defp traverse([{term, depth, reverse_path} | rest], counts, surface) do
    term_count = counts.term_count + 1

    with :ok <-
           within_limit(
             surface,
             :term_count,
             @max_term_slots,
             term_count,
             reverse_path
           ),
         {:ok, binary_bytes} <-
           count_binary(term, counts.binary_bytes, surface, reverse_path),
         :ok <- check_depth(term, depth, surface, reverse_path),
         {:ok, children} <- children(term, depth, surface, reverse_path) do
      traverse(children ++ rest, %{term_count: term_count, binary_bytes: binary_bytes}, surface)
    end
  end

  defp count_binary(term, binary_bytes, surface, reverse_path) when is_binary(term) do
    actual = binary_bytes + byte_size(term)

    case within_limit(surface, :binary_bytes, @max_binary_bytes, actual, reverse_path) do
      :ok -> {:ok, actual}
      {:error, error} -> {:error, error}
    end
  end

  defp count_binary(_term, binary_bytes, _surface, _reverse_path), do: {:ok, binary_bytes}

  defp check_depth(term, depth, surface, reverse_path)
       when is_map(term) or is_list(term) or is_tuple(term) do
    within_limit(surface, :nesting_depth, @max_depth, depth, reverse_path)
  end

  defp check_depth(_term, _depth, _surface, _reverse_path), do: :ok

  defp children(term, depth, surface, reverse_path) when is_map(term) do
    width = map_size(term)

    with :ok <- within_limit(surface, :collection_width, @max_width, width, reverse_path) do
      children =
        term
        |> Map.to_list()
        |> Enum.sort()
        |> Enum.with_index()
        |> Enum.flat_map(fn {{key, value}, index} ->
          [
            work_item(key, depth, [{:map_key, index} | reverse_path]),
            work_item(value, depth, [{:map_value, index} | reverse_path])
          ]
        end)

      {:ok, children}
    end
  end

  defp children(term, depth, surface, reverse_path) when is_tuple(term) do
    width = tuple_size(term)

    with :ok <- within_limit(surface, :collection_width, @max_width, width, reverse_path) do
      children =
        term
        |> Tuple.to_list()
        |> Enum.with_index()
        |> Enum.map(fn {child, index} ->
          work_item(child, depth, [index | reverse_path])
        end)

      {:ok, children}
    end
  end

  defp children(term, depth, surface, reverse_path) when is_list(term) do
    list_children(term, depth, surface, reverse_path, 0, [])
  end

  defp children(_term, _depth, _surface, _reverse_path), do: {:ok, []}

  defp list_children([], _depth, _surface, _reverse_path, _width, reverse_children) do
    {:ok, Enum.reverse(reverse_children)}
  end

  defp list_children([head | tail], depth, surface, reverse_path, width, reverse_children) do
    actual = width + 1

    case within_limit(surface, :collection_width, @max_width, actual, reverse_path) do
      :ok ->
        child = work_item(head, depth, [width | reverse_path])
        list_children(tail, depth, surface, reverse_path, actual, [child | reverse_children])

      {:error, error} ->
        {:error, error}
    end
  end

  defp list_children(tail, depth, _surface, reverse_path, width, reverse_children) do
    improper_tail = work_item(tail, depth, [width | reverse_path])
    {:ok, Enum.reverse([improper_tail | reverse_children])}
  end

  defp work_item(term, parent_depth, reverse_path) do
    depth =
      if is_map(term) or is_list(term) or is_tuple(term) do
        parent_depth + 1
      else
        parent_depth
      end

    {term, depth, reverse_path}
  end

  defp within_limit(_surface, _resource, limit, actual, _reverse_path) when actual <= limit,
    do: :ok

  defp within_limit(surface, resource, limit, actual, reverse_path) do
    limit_error(surface, resource, limit, actual, Enum.reverse(reverse_path))
  end

  defp limit_error(_surface, resource, limit, actual, path) do
    {:error,
     Error.validation_error("stored flow map exceeds resource limit", %{
       profile: :stored,
       resource: resource,
       limit: limit,
       actual: actual,
       path: path
     })}
  end
end
