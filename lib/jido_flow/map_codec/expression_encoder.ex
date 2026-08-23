defmodule Jido.Flow.MapCodec.ExpressionEncoder do
  @moduledoc false

  alias Jido.Flow.Condition
  alias Jido.Flow.MapCodec.DataEncoder
  alias Jido.Flow.Ref

  @doc false
  def encode!(%Ref{type: :input, path: path}, _error_path) do
    %{"type" => "input", "path" => encode_path!(path)}
  end

  def encode!(%Ref{type: :context, path: path}, _error_path) do
    %{"type" => "context", "path" => encode_path!(path)}
  end

  def encode!(%Ref{type: :result, node: node, path: path}, _error_path) do
    %{"type" => "result", "node" => node, "path" => encode_path!(path)}
  end

  def encode!(%Ref{type: :value, value: value}, error_path) do
    %{"type" => "value", "value" => DataEncoder.encode!(value, error_path ++ ["value"])}
  end

  def encode!(%Ref{type: type, path: path}, _error_path)
      when type in [:item, :accumulator, :state, :body_result] do
    %{"type" => Atom.to_string(type), "path" => encode_path!(path)}
  end

  def encode!(%Ref{type: type}, _error_path) when type in [:item_index, :item_id] do
    %{"type" => Atom.to_string(type)}
  end

  def encode!(%Ref{type: :iteration_index}, _error_path) do
    %{"type" => "iteration_index", "path" => []}
  end

  def encode!(%{} = map, error_path) when not is_struct(map) do
    %{
      "type" => "map",
      "entries" =>
        map
        |> Enum.sort_by(fn {key, _value} -> DataEncoder.key_sort_key(key) end)
        |> Enum.with_index()
        |> Enum.map(fn {{key, value}, index} ->
          %{
            "key" => DataEncoder.encode_map_key!(key, error_path ++ [{:map_key, index}]),
            "value" => encode!(value, error_path ++ [{:map_value, index}])
          }
        end)
    }
  end

  def encode!(list, error_path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.map(fn {value, index} -> encode!(value, error_path ++ [index]) end)
  end

  def encode!(value, error_path), do: value |> Ref.value() |> encode!(error_path)

  @doc false
  def encode_condition!(%Condition{operator: operator, operands: operands}, error_path) do
    %{
      "operator" => Atom.to_string(operator),
      "operands" =>
        operands
        |> Enum.with_index()
        |> Enum.map(fn
          {%Condition{} = condition, index} ->
            encode_condition!(condition, error_path ++ ["operands", index])

          {expression, index} ->
            encode!(expression, error_path ++ ["operands", index])
        end)
    }
  end

  defp encode_path!(path), do: Enum.map(path, &DataEncoder.encode_key!/1)
end
