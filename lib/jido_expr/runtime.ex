defmodule Jido.Expr.Runtime do
  @moduledoc false

  alias Jido.Expr
  alias Jido.Expr.Limits

  @doc false
  @spec evaluate(term(), keyword()) :: {:ok, term()} | {:error, term()}
  def evaluate(value, options) do
    with {:ok, state} <- Limits.new(options, [:resolve]),
         {:ok, result, _state} <- visit(value, state, [], 0, :evaluate) do
      {:ok, result}
    end
  end

  @doc false
  @spec validate(term(), keyword()) :: :ok | {:error, term()}
  def validate(value, options) do
    with {:ok, state} <- Limits.new(options, [:validate_leaf]),
         {:ok, _value, _state} <- visit(value, state, [], 0, :validate) do
      :ok
    end
  end

  defp visit(value, state, path, depth, mode) do
    with {:ok, state} <- Limits.enter(state, value, path, depth) do
      visit_value(value, state, path, depth, mode)
    end
  end

  defp visit_value(%Expr{} = expression, state, path, depth, mode) when mode != :data do
    with {:ok, _} <- shape(expression, path) do
      expression(expression, state, path, depth, mode)
    end
  end

  defp visit_value(%_{} = value, state, path, depth, mode) when mode != :data,
    do: host(value, state, path, depth, mode)

  defp visit_value(value, state, path, depth, mode) when is_map(value) do
    value
    |> Map.to_list()
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, %{}, state}, fn {key, child}, {:ok, result, state} ->
      case map_pair(key, child, state, path, depth, mode) do
        {:ok, child, state} -> {:cont, {:ok, Map.put(result, key, child), state}}
        error -> {:halt, error}
      end
    end)
  end

  defp visit_value(value, state, path, depth, mode) when is_list(value),
    do: list(value, state, path, depth, mode, 0, [])

  defp visit_value(value, state, path, depth, :data) when is_tuple(value) do
    with {:ok, _values, state} <- list(Tuple.to_list(value), state, path, depth, :data, 0, []) do
      {:ok, value, state}
    end
  end

  defp visit_value(value, state, _path, _depth, mode)
       when mode == :data or is_atom(value) or is_number(value) or is_binary(value),
       do: {:ok, value, state}

  defp visit_value(value, _state, path, _depth, _mode),
    do: Limits.fail(:unsupported_value, path, nil, %{type: Limits.type(value)})

  defp map_pair(key, value, state, path, depth, mode) do
    if mode == :data or is_atom(key) or is_binary(key) or is_integer(key) do
      child_path = path ++ [safe_key(key)]

      with {:ok, _key, state} <- visit(key, state, child_path, depth + 1, :data) do
        visit(value, state, child_path, depth + 1, mode)
      end
    else
      Limits.fail(:invalid_map_key, path, nil, %{type: Limits.type(key)})
    end
  end

  defp safe_key(key) when is_atom(key) or is_binary(key) or is_integer(key), do: key
  defp safe_key(_key), do: :key

  defp list([], state, _path, _depth, _mode, _index, result),
    do: {:ok, Enum.reverse(result), state}

  defp list([head | tail], state, path, depth, mode, index, result) do
    with {:ok, value, state} <- visit(head, state, path ++ [index], depth + 1, mode) do
      list(tail, state, path, depth, mode, index + 1, [value | result])
    end
  end

  defp list(tail, state, path, depth, :data, index, result) do
    with {:ok, tail, state} <- visit(tail, state, path ++ [index], depth + 1, :data) do
      {:ok, Enum.reduce(result, tail, &[&1 | &2]), state}
    end
  end

  defp list(_tail, _state, path, _depth, _mode, index, _result),
    do: Limits.fail(:improper_list, path ++ [index])

  defp shape(%Expr{operator: operator, operands: operands}, path) do
    case Expr.new(operator, operands) do
      {:ok, _} = ok -> ok
      {:error, error} -> {:error, %{error | path: path}}
    end
  end

  defp expression(%Expr{} = value, state, path, depth, :validate) do
    with {:ok, _operands, state} <-
           list(value.operands, state, path ++ [:operands], depth, :validate, 0, []) do
      {:ok, value, state}
    end
  end

  defp expression(%Expr{operator: operator, operands: operands}, state, path, depth, :evaluate)
       when operator in [:all, :any],
       do: boolean(operands, operator, state, path, depth, 0)

  defp expression(%Expr{operator: operator, operands: operands}, state, path, depth, :evaluate) do
    with {:ok, values, state} <-
           list(operands, state, path ++ [:operands], depth, :evaluate, 0, []),
         {:ok, result, state} <- operation(operator, values, state, path, depth),
         {:ok, state} <- Limits.enter(state, result, path, depth, operator) do
      {:ok, result, state}
    end
  end

  defp boolean([], operator, state, _path, _depth, _index),
    do: {:ok, operator == :all, state}

  defp boolean([head | tail], operator, state, path, depth, index) do
    operand_path = path ++ [:operands, index]

    with {:ok, value, state} <- visit(head, state, operand_path, depth + 1, :evaluate) do
      cond do
        not is_boolean(value) ->
          type_error(:invalid_boolean_operand, operator, [value], operand_path)

        operator == :all and not value ->
          {:ok, false, state}

        operator == :any and value ->
          {:ok, true, state}

        true ->
          boolean(tail, operator, state, path, depth, index + 1)
      end
    end
  end

  defp host(value, state, path, depth, :evaluate) do
    case Map.get(state, :resolve) do
      nil ->
        Limits.fail(:unsupported_value, path, nil, %{type: :struct})

      callback ->
        case Limits.callback(callback, value, path) do
          {:ok, result} -> visit(result, state, path, depth, :data)
          {:error, error} -> Limits.callback_error(error, path)
          _ -> Limits.fail(:invalid_callback_return, path)
        end
    end
  end

  defp host(value, state, path, _depth, :validate) do
    case Map.get(state, :validate_leaf) do
      nil ->
        Limits.fail(:unsupported_value, path, nil, %{type: :struct})

      callback ->
        case Limits.callback(callback, value, path) do
          :ok -> {:ok, value, state}
          {:error, error} -> Limits.callback_error(error, path)
          _ -> Limits.fail(:invalid_callback_return, path)
        end
    end
  end

  defp operation(operator, [left, right], state, path, depth) when operator in [:eq, :neq] do
    with {:ok, equal?, state} <- equal(left, right, state, path, depth) do
      {:ok, if(operator == :eq, do: equal?, else: not equal?), state}
    end
  end

  defp operation(operator, [left, right] = values, state, path, _depth)
       when operator in [:lt, :lte, :gt, :gte] do
    if (is_number(left) and is_number(right)) or (is_binary(left) and is_binary(right)) do
      result =
        case operator do
          :lt -> left < right
          :lte -> left <= right
          :gt -> left > right
          :gte -> left >= right
        end

      {:ok, result, state}
    else
      type_error(:invalid_ordering_operands, operator, values, path)
    end
  end

  defp operation(:in, [left, right], state, path, depth) do
    if proper_list?(right) do
      member(left, right, state, path, depth)
    else
      type_error(:invalid_membership_right_operand, :in, [right], path)
    end
  end

  defp operation(:not, [value], state, _path, _depth) when is_boolean(value),
    do: {:ok, not value, state}

  defp operation(:not, values, _state, path, _depth),
    do: type_error(:invalid_boolean_operand, :not, values, path)

  defp operation(:concat, [left, right], state, path, _depth)
       when is_binary(left) and is_binary(right) do
    if state.bytes + byte_size(left) + byte_size(right) > state.max_binary_bytes do
      Limits.fail(:max_binary_bytes, path, :concat)
    else
      {:ok, left <> right, state}
    end
  end

  defp operation(:concat, values, _state, path, _depth),
    do: type_error(:invalid_binary_operands, :concat, values, path)

  defp operation(operator, values, state, path, _depth) do
    cond do
      not numeric_operands?(operator, values) ->
        type_error(:invalid_numeric_operands, operator, values, path)

      operator in [:divide, :div, :rem] and List.last(values) == 0 ->
        Limits.fail(:division_by_zero, path, operator)

      true ->
        arithmetic(operator, values, state, path)
    end
  end

  defp numeric_operands?(operator, values) when operator in [:div, :rem],
    do: Enum.all?(values, &is_integer/1)

  defp numeric_operands?(_operator, values), do: Enum.all?(values, &is_number/1)

  defp arithmetic(operator, values, state, path) do
    result =
      case {operator, values} do
        {:add, [left, right]} -> left + right
        {:subtract, [left, right]} -> left - right
        {:multiply, [left, right]} -> left * right
        {:divide, [left, right]} -> left / right
        {:negate, [value]} -> -value
        {:div, [left, right]} -> div(left, right)
        {:rem, [left, right]} -> rem(left, right)
        {:min, [left, right]} -> min(left, right)
        {:max, [left, right]} -> max(left, right)
        {:abs, [value]} -> abs(value)
      end

    {:ok, result, state}
  rescue
    ArithmeticError -> Limits.fail(:arithmetic_error, path, operator)
  end

  defp equal(left, right, state, path, depth) do
    with {:ok, _left, state} <- visit(left, state, path, depth, :data),
         {:ok, _right, state} <- visit(right, state, path, depth, :data) do
      {:ok, left == right, state}
    end
  end

  defp member(_left, [], state, _path, _depth), do: {:ok, false, state}

  defp member(left, [head | tail], state, path, depth) do
    with {:ok, equal?, state} <- equal(left, head, state, path, depth) do
      if equal?, do: {:ok, true, state}, else: member(left, tail, state, path, depth)
    end
  end

  defp proper_list?([]), do: true
  defp proper_list?([_ | tail]), do: proper_list?(tail)
  defp proper_list?(_), do: false

  defp type_error(reason, operator, values, path),
    do: Limits.fail(reason, path, operator, %{types: Enum.map(values, &Limits.type/1)})
end
