defmodule Jido.Flow.Compiler.Condition do
  @moduledoc false

  alias Jido.Flow.Error
  alias Jido.Flow.Compiler.Expression
  alias Jido.Flow.Condition

  @doc false
  @spec evaluate(Condition.t(), map(), String.t(), term()) ::
          {:ok, boolean()} | {:error, Exception.t()}
  def evaluate(%Condition{operator: :all, operands: conditions}, state, node, option) do
    Enum.reduce_while(conditions, {:ok, true}, fn condition, {:ok, true} ->
      case evaluate(condition, state, node, option) do
        {:ok, true} -> {:cont, {:ok, true}}
        {:ok, false} -> {:halt, {:ok, false}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  def evaluate(%Condition{operator: :any, operands: conditions}, state, node, option) do
    Enum.reduce_while(conditions, {:ok, false}, fn condition, {:ok, false} ->
      case evaluate(condition, state, node, option) do
        {:ok, true} -> {:halt, {:ok, true}}
        {:ok, false} -> {:cont, {:ok, false}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  def evaluate(%Condition{operator: :not, operands: [condition]}, state, node, option) do
    case evaluate(condition, state, node, option) do
      {:ok, result} -> {:ok, not result}
      {:error, error} -> {:error, error}
    end
  end

  def evaluate(
        %Condition{operator: operator, operands: [left, right]},
        state,
        node,
        option
      ) do
    with {:ok, left} <- Expression.resolve(left, state),
         {:ok, right} <- Expression.resolve(right, state) do
      evaluate_comparison(operator, left, right, node, option)
    end
  end

  defp evaluate_comparison(:eq, left, right, _node, _option), do: {:ok, left == right}
  defp evaluate_comparison(:neq, left, right, _node, _option), do: {:ok, left != right}

  defp evaluate_comparison(operator, left, right, node, option)
       when operator in [:lt, :lte, :gt, :gte] do
    if comparable_values?(left, right) do
      result =
        case operator do
          :lt -> left < right
          :lte -> left <= right
          :gt -> left > right
          :gte -> left >= right
        end

      {:ok, result}
    else
      invalid_condition(operator, :invalid_ordering_operands, left, right, node, option)
    end
  end

  defp evaluate_comparison(:in, left, right, node, option) do
    case proper_list_member(right, left, false) do
      {:ok, member?} ->
        {:ok, member?}

      :error ->
        invalid_condition(
          :in,
          :invalid_membership_right_operand,
          left,
          right,
          node,
          option
        )
    end
  end

  defp comparable_values?(left, right) do
    (is_number(left) and is_number(right)) or (is_binary(left) and is_binary(right))
  end

  defp proper_list_member([], _value, member?), do: {:ok, member?}

  defp proper_list_member([head | tail], value, false) do
    proper_list_member(tail, value, head == value)
  end

  defp proper_list_member([_head | tail], value, true) do
    proper_list_member(tail, value, true)
  end

  defp proper_list_member(_value, _member, _member?), do: :error

  defp invalid_condition(operator, reason, left, right, node, option) do
    {:error,
     Error.execution_error("invalid choice condition operands", %{
       phase: :choice_condition,
       node: node,
       option: option,
       operator: operator,
       reason: reason,
       left_type: value_type(left),
       right_type: value_type(right),
       retry: false
     })}
  end

  defp value_type(value) when is_number(value), do: :number
  defp value_type(value) when is_binary(value), do: :binary
  defp value_type(value) when is_list(value), do: :list
  defp value_type(value) when is_map(value), do: :map
  defp value_type(value) when is_atom(value), do: :atom
  defp value_type(value) when is_tuple(value), do: :tuple
  defp value_type(_value), do: :other
end
