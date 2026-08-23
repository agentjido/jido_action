defmodule Jido.Flow.MapCodec.ExpressionDecoder do
  @moduledoc false

  alias Jido.Flow.Condition
  alias Jido.Flow.MapCodec.DataDecoder
  alias Jido.Flow.MapCodec.ErrorPath
  alias Jido.Flow.MapCodec.RecordValidator
  alias Jido.Flow.Ref

  @stored_ref_types [
    "input",
    "context",
    "result",
    "value",
    "item",
    "item_index",
    "item_id",
    "accumulator",
    "state",
    "iteration_index",
    "body_result"
  ]

  @doc false
  def decode(%{} = map) do
    case Map.fetch(map, "type") do
      {:ok, "map"} ->
        decode_expression_map(map)

      {:ok, type} when type in @stored_ref_types ->
        decode_ref(map, type)

      {:ok, type} ->
        ErrorPath.error("unknown flow ref type: #{inspect(type)}", %{type: type})

      :error ->
        ErrorPath.error("stored flow expression must be a tagged record", %{
          record: :expression
        })
    end
  end

  def decode(list) when is_list(list) do
    if List.improper?(list) do
      ErrorPath.error("flow expression must be a proper list", %{expression: inspect(list)})
    else
      decode_expression_list(list)
    end
  end

  def decode(value) do
    ErrorPath.error("stored flow expression must be a tagged record", %{
      record: :expression,
      value: value
    })
  end

  @doc false
  def decode_condition(condition), do: decode_condition(condition, :flow)

  @doc false
  def decode_condition(%{} = condition, scope) do
    with :ok <- RecordValidator.validate_condition_record(condition),
         {:ok, operator} <-
           RecordValidator.fetch_required(
             condition,
             :operator,
             "choice condition operator is required"
           ),
         {:ok, operator} <-
           decode_condition_operator(operator)
           |> ErrorPath.prepend([RecordValidator.field(:operator)]),
         {:ok, operands} <-
           RecordValidator.fetch_required(
             condition,
             :operands,
             "choice condition operands are required"
           ),
         {:ok, operands} <-
           decode_condition_operands(operands, operator, scope)
           |> ErrorPath.prepend([RecordValidator.field(:operands)]) do
      Condition.validate(%Condition{operator: operator, operands: operands}, scope)
    end
  end

  def decode_condition(_condition, _scope) do
    ErrorPath.error("choice condition must be a map")
  end

  defp decode_expression_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, &decode_expression_list_item/2)
    |> reverse_decoded_expression_list()
  end

  defp decode_expression_list_item({value, index}, {:ok, acc}) do
    case decode(value) |> ErrorPath.prepend([index]) do
      {:ok, value} -> {:cont, {:ok, [value | acc]}}
      {:error, error} -> {:halt, {:error, error}}
    end
  end

  defp reverse_decoded_expression_list({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_decoded_expression_list({:error, error}), do: {:error, error}

  defp decode_condition_operands(operands, operator, scope) when is_list(operands) do
    if List.improper?(operands) do
      ErrorPath.error("choice condition operands must be a list")
    else
      decoder =
        if operator in [:all, :any, :not],
          do: &decode_condition(&1, scope),
          else: &decode/1

      operands
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {operand, index}, {:ok, acc} ->
        case decoder.(operand) |> ErrorPath.prepend([index]) do
          {:ok, operand} -> {:cont, {:ok, [operand | acc]}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
      |> case do
        {:ok, operands} -> {:ok, Enum.reverse(operands)}
        {:error, error} -> {:error, error}
      end
    end
  end

  defp decode_condition_operands(_operands, _operator, _scope) do
    ErrorPath.error("choice condition operands must be a list")
  end

  defp decode_condition_operator(operator) when is_binary(operator) do
    case operator do
      "eq" -> {:ok, :eq}
      "neq" -> {:ok, :neq}
      "lt" -> {:ok, :lt}
      "lte" -> {:ok, :lte}
      "gt" -> {:ok, :gt}
      "gte" -> {:ok, :gte}
      "in" -> {:ok, :in}
      "all" -> {:ok, :all}
      "any" -> {:ok, :any}
      "not" -> {:ok, :not}
      _ -> ErrorPath.error("unsupported choice condition operator", %{operator: operator})
    end
  end

  defp decode_condition_operator(operator) do
    ErrorPath.error("unsupported choice condition operator", %{operator: operator})
  end

  defp decode_ref(map, "input") do
    with :ok <- RecordValidator.validate_ref_record(map, "input"),
         {:ok, path} <- decode_stored_path(Map.fetch!(map, "path")) do
      {:ok, Ref.input(path)}
    end
  end

  defp decode_ref(map, "context") do
    with :ok <- RecordValidator.validate_ref_record(map, "context"),
         {:ok, path} <- decode_stored_path(Map.fetch!(map, "path")) do
      {:ok, Ref.context(path)}
    end
  end

  defp decode_ref(map, "result") do
    with :ok <- RecordValidator.validate_ref_record(map, "result"),
         {:ok, node} <- decode_result_node(Map.fetch!(map, "node")),
         {:ok, path} <- decode_stored_path(Map.fetch!(map, "path")) do
      {:ok, Ref.result(node, path)}
    end
  end

  defp decode_ref(map, "value") do
    with :ok <- RecordValidator.validate_ref_record(map, "value"),
         {:ok, value} <-
           DataDecoder.decode(Map.fetch!(map, "value")) |> ErrorPath.prepend(["value"]) do
      {:ok, Ref.value(value)}
    end
  end

  defp decode_ref(map, type)
       when type in ["item", "accumulator", "state", "body_result"] do
    with :ok <- RecordValidator.validate_ref_record(map, type),
         {:ok, path} <- decode_stored_path(Map.fetch!(map, "path")) do
      {:ok, local_path_ref(type, path)}
    end
  end

  defp decode_ref(map, "iteration_index") do
    with :ok <- RecordValidator.validate_ref_record(map, "iteration_index"),
         {:ok, []} <- decode_stored_path(Map.fetch!(map, "path")) do
      {:ok, Ref.iteration_index()}
    else
      {:ok, path} -> ErrorPath.error("iteration index ref path must be empty", %{path: path})
      {:error, error} -> {:error, error}
    end
  end

  defp decode_ref(map, type) when type in ["item_index", "item_id"] do
    with :ok <- RecordValidator.validate_ref_record(map, type) do
      {:ok, local_scalar_ref(type)}
    end
  end

  defp local_path_ref(type, path) when type in [:item, "item"], do: Ref.item(path)

  defp local_path_ref(type, path) when type in [:accumulator, "accumulator"] do
    Ref.accumulator(path)
  end

  defp local_path_ref(type, path) when type in [:state, "state"], do: Ref.state(path)

  defp local_path_ref(type, path) when type in [:body_result, "body_result"] do
    Ref.body_result(path)
  end

  defp local_scalar_ref(type) when type in [:item_index, "item_index"], do: Ref.item_index()
  defp local_scalar_ref(type) when type in [:item_id, "item_id"], do: Ref.item_id()

  defp decode_expression_map(map) do
    with :ok <-
           RecordValidator.validate_record(
             map,
             ["type", "entries"],
             ["type", "entries"],
             :encoded_map
           ),
         {:ok, entries} <-
           RecordValidator.exact_fetch_required(
             map,
             "entries",
             "flow expression map entries are required"
           ),
         {:ok, entries} <- DataDecoder.decode_entries(entries, &decode/1) do
      {:ok, Map.new(entries)}
    end
  end

  defp decode_result_node(node) when is_binary(node), do: {:ok, node}

  defp decode_result_node(node) do
    ErrorPath.error("stored result ref node must be a binary", %{node: node})
  end

  defp decode_stored_path(path) when is_list(path) do
    if List.improper?(path) do
      ErrorPath.error("flow ref path must be a list", %{path: inspect(path)})
    else
      path
      |> Enum.reduce_while({:ok, []}, fn segment, {:ok, acc} ->
        case DataDecoder.decode_key(segment) do
          {:ok, segment} -> {:cont, {:ok, [segment | acc]}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
      |> case do
        {:ok, path} -> {:ok, Enum.reverse(path)}
        {:error, error} -> {:error, error}
      end
    end
  end

  defp decode_stored_path(path) do
    ErrorPath.error("flow ref path must be a list", %{path: path})
  end
end
