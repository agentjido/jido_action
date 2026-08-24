defmodule Jido.Flow.MapCodec.ExpressionEncoder do
  @moduledoc false

  alias Jido.Flow.Condition
  alias Jido.Flow.MapCodec.DataEncoder
  alias Jido.Flow.Ref

  @doc false
  def encode!(%Ref{type: :input, path: path}, error_path, registry) do
    %{"type" => "input", "path" => encode_path!(path, error_path, registry)}
  end

  def encode!(%Ref{type: :context, path: path}, error_path, registry) do
    %{"type" => "context", "path" => encode_path!(path, error_path, registry)}
  end

  def encode!(%Ref{type: :result, node: node, path: path}, error_path, registry) do
    %{
      "type" => "result",
      "node" => node,
      "path" => encode_path!(path, error_path, registry)
    }
  end

  def encode!(%Ref{type: :value, value: value}, error_path, registry) do
    %{
      "type" => "value",
      "value" => DataEncoder.encode!(value, error_path ++ ["value"], registry)
    }
  end

  def encode!(%Ref{type: type, path: path}, error_path, registry)
      when type in [:item, :accumulator, :state, :body_result] do
    %{"type" => Atom.to_string(type), "path" => encode_path!(path, error_path, registry)}
  end

  def encode!(%Ref{type: type}, _error_path, _registry) when type in [:item_index, :item_id] do
    %{"type" => Atom.to_string(type)}
  end

  def encode!(%Ref{type: :iteration_index}, _error_path, _registry) do
    %{"type" => "iteration_index", "path" => []}
  end

  def encode!(%{} = map, error_path, registry) when not is_struct(map) do
    %{
      "type" => "map",
      "entries" =>
        map
        |> Enum.sort_by(fn {key, _value} -> DataEncoder.key_sort_key(key) end)
        |> Enum.with_index()
        |> Enum.map(fn {{key, value}, index} ->
          %{
            "key" =>
              DataEncoder.encode_map_key!(key, error_path ++ [{:map_key, index}], registry),
            "value" => encode!(value, error_path ++ [{:map_value, index}], registry)
          }
        end)
    }
  end

  def encode!(list, error_path, registry) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.map(fn {value, index} -> encode!(value, error_path ++ [index], registry) end)
  end

  def encode!(value, error_path, registry),
    do: value |> Ref.value() |> encode!(error_path, registry)

  @doc false
  def encode_condition!(%Condition{operator: operator, operands: operands}, error_path, registry) do
    %{
      "operator" => Atom.to_string(operator),
      "operands" =>
        operands
        |> Enum.with_index()
        |> Enum.map(fn
          {%Condition{} = condition, index} ->
            encode_condition!(condition, error_path ++ ["operands", index], registry)

          {expression, index} ->
            encode!(expression, error_path ++ ["operands", index], registry)
        end)
    }
  end

  defp encode_path!(path, error_path, registry) do
    path
    |> Enum.with_index()
    |> Enum.map(fn {segment, index} ->
      DataEncoder.encode_map_key!(segment, error_path ++ ["path", index], registry)
    end)
  end
end
