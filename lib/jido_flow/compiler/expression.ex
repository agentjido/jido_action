defmodule Jido.Flow.Compiler.Expression do
  @moduledoc false

  alias Jido.Action.Error
  alias Jido.Action.Output
  alias Jido.Flow.Node
  alias Jido.Flow.Ref
  alias Runic.Workflow

  @doc false
  def resolve(%Ref{type: :input, path: path}, state), do: {:ok, fetch_path(state.input, path)}

  def resolve(%Ref{type: :context, path: path}, state) do
    {:ok, fetch_path(state.context, path)}
  end

  def resolve(%Ref{type: :value, value: value}, _state), do: {:ok, value}

  def resolve(%Ref{type: :result, node: node, path: path}, state) do
    {:ok, state.results |> Map.get(node) |> fetch_path(path)}
  end

  def resolve(%Ref{type: :item, path: path}, state) do
    {:ok, state |> Map.get(:item) |> fetch_path(path)}
  end

  def resolve(%Ref{type: :item_index}, state), do: {:ok, Map.get(state, :item_index)}
  def resolve(%Ref{type: :item_id}, state), do: {:ok, Map.get(state, :item_id)}

  def resolve(%Ref{type: :accumulator, path: path}, state) do
    {:ok, state |> Map.get(:accumulator) |> fetch_path(path)}
  end

  def resolve(%Ref{type: :state, path: path}, state) do
    {:ok, state |> Map.get(:iterate_state) |> fetch_path(path)}
  end

  def resolve(%Ref{type: :iteration_index}, state) do
    {:ok, Map.get(state, :iteration_index)}
  end

  def resolve(%Ref{type: :body_result, path: path}, state) do
    {:ok, state |> Map.get(:body_result) |> fetch_path(path)}
  end

  def resolve(%Ref{type: type}, _state) do
    {:error, Error.validation_error("unsupported flow ref type: #{inspect(type)}", %{type: type})}
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
  def extract_return(return_expr, workflow, input, context) do
    result_nodes = return_expr |> Node.collect_result_refs() |> Enum.uniq()
    facts_by_node = Workflow.results(workflow, result_nodes, facts: true, all: true)

    result_nodes
    |> Enum.reduce_while({:ok, %{}}, fn node, {:ok, acc} ->
      case Map.get(facts_by_node, node, []) do
        [] ->
          {:halt, {:error, Error.execution_error("flow execution produced no final state")}}

        facts ->
          value = facts |> List.last() |> Map.fetch!(:value)
          {:cont, {:ok, Map.put(acc, node, value)}}
      end
    end)
    |> case do
      {:ok, results} ->
        resolve(return_expr, %{input: input, context: context, results: results})

      {:error, error} ->
        {:error, error}
    end
  end

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

  defp fetch_path(value, []), do: value
  defp fetch_path(nil, _path), do: nil

  defp fetch_path(value, [key | rest]) when is_map(value) do
    value
    |> fetch_key(key)
    |> fetch_path(rest)
  end

  defp fetch_path(value, [key | rest]) when is_list(value) and is_integer(key) and key >= 0 do
    value
    |> list_at(key)
    |> fetch_path(rest)
  end

  defp fetch_path(_value, _path), do: nil

  defp list_at([head | _tail], 0), do: head
  defp list_at([_head | tail], index), do: list_at(tail, index - 1)
  defp list_at(_tail, _index), do: nil

  defp fetch_key(map, key) do
    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      is_atom(key) and Map.has_key?(map, Atom.to_string(key)) -> Map.get(map, Atom.to_string(key))
      true -> nil
    end
  end
end
