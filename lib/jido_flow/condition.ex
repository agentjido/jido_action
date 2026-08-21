defmodule Jido.Flow.Condition do
  @moduledoc """
  A closed, data-only condition used by a Flow choice.
  """

  alias Jido.Action
  alias Jido.Action.Error
  alias Jido.Flow.Node

  import Kernel, except: [in: 2]

  @comparison_operators [:eq, :neq, :lt, :lte, :gt, :gte, :in]
  @group_operators [:all, :any]
  @operators @comparison_operators ++ @group_operators ++ [:not]

  @type operator :: :eq | :neq | :lt | :lte | :gt | :gte | :in | :all | :any | :not
  @type t :: %__MODULE__{operator: operator(), operands: [term()]}

  @enforce_keys [:operator, :operands]
  defstruct [:operator, :operands]

  @doc """
  Builds a condition from an operator and ordered operands.
  """
  @spec new(operator(), list()) :: {:ok, t()} | {:error, Exception.t()}
  def new(operator, operands) do
    with :ok <- validate_operator(operator),
         :ok <- validate_arity(operator, operands),
         {:ok, operands} <- normalize_operands(operator, operands) do
      {:ok, %__MODULE__{operator: operator, operands: operands}}
    end
  end

  @doc """
  Revalidates a canonical condition.
  """
  @spec new(t()) :: {:ok, t()} | {:error, Exception.t()}
  def new(%__MODULE__{} = condition), do: new(condition.operator, condition.operands)

  def new(_condition) do
    {:error,
     Error.validation_error("choice condition must be a Jido.Flow.Condition", %{path: []})}
  end

  @doc """
  Builds a condition or raises on validation failure.
  """
  @spec new!(operator(), list()) :: t() | no_return()
  def new!(operator, operands) do
    case new(operator, operands) do
      {:ok, condition} -> condition
      {:error, error} -> raise error
    end
  end

  for operator <- @comparison_operators do
    @doc false
    def unquote(operator)(left, right), do: new!(unquote(operator), [left, right])
  end

  @doc false
  def all(conditions), do: new!(:all, conditions)

  @doc false
  def any(conditions), do: new!(:any, conditions)

  @doc false
  def not condition, do: new!(:not, [condition])

  @doc false
  @spec result_deps(t()) :: [String.t()]
  def result_deps(%__MODULE__{operator: operator, operands: operands})
      when Kernel.in(operator, @comparison_operators) do
    operands
    |> Enum.flat_map(&Node.collect_result_refs/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def result_deps(%__MODULE__{operands: operands}) do
    operands
    |> Enum.flat_map(&result_deps/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc false
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{operator: operator, operands: operands}) do
    %{
      operator: operator,
      operands:
        Enum.map(operands, fn
          %__MODULE__{} = condition -> to_map(condition)
          expression -> Node.expression_to_map(expression)
        end)
    }
  end

  defp validate_operator(operator) when Kernel.in(operator, @operators), do: :ok

  defp validate_operator(_operator) do
    {:error, Error.validation_error("unsupported choice condition operator", %{path: []})}
  end

  defp validate_arity(operator, operands)
       when is_list(operands) and Kernel.in(operator, @comparison_operators) do
    if length(operands) == 2 do
      :ok
    else
      {:error,
       Error.validation_error(
         "choice condition #{inspect(operator)} must have exactly 2 operands",
         %{
           path: []
         }
       )}
    end
  end

  defp validate_arity(operator, operands)
       when is_list(operands) and Kernel.in(operator, @group_operators) do
    if operands == [] do
      {:error,
       Error.validation_error(
         "choice condition #{inspect(operator)} must have at least 1 condition",
         %{
           path: []
         }
       )}
    else
      :ok
    end
  end

  defp validate_arity(:not, operands) when is_list(operands) do
    if length(operands) == 1 do
      :ok
    else
      {:error,
       Error.validation_error("choice condition :not must have exactly 1 condition", %{path: []})}
    end
  end

  defp validate_arity(_operator, _operands) do
    {:error, Error.validation_error("choice condition operands must be a list", %{path: []})}
  end

  defp normalize_operands(operator, operands) when Kernel.in(operator, @comparison_operators) do
    operands
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {operand, index}, {:ok, acc} ->
      case normalize_expression(operand, [index]) do
        {:ok, operand} -> {:cont, {:ok, [operand | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> reverse_ok_list()
  end

  defp normalize_operands(operator, operands)
       when Kernel.in(operator, @group_operators) or operator == :not do
    operands
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {operand, index}, {:ok, acc} ->
      case new(operand) do
        {:ok, condition} ->
          {:cont, {:ok, [condition | acc]}}

        {:error, _error} ->
          {:halt,
           {:error,
            Error.validation_error(
              "choice condition #{inspect(operator)} contains an invalid child condition",
              %{
                path: [index]
              }
            )}}
      end
    end)
    |> reverse_ok_list()
  end

  defp normalize_expression(expression, path) do
    with {:ok, expression} <- Node.normalize_expression(expression),
         :ok <- Node.validate_expression(expression),
         :ok <- validate_static_expression(expression) do
      {:ok, expression}
    else
      {:error, error} -> {:error, translate_expression_error(error, path)}
    end
  end

  defp validate_static_expression(expression) do
    case Action.validate_static_data(expression) do
      :ok ->
        :ok

      {:error, _reason} ->
        {:error, Error.validation_error("unsupported choice condition expression")}
    end
  end

  defp translate_expression_error(error, path) do
    details = Map.get(error, :details, %{})
    nested_path = path ++ Map.get(details, :path, [])

    cond do
      String.contains?(error.message, "invalid ref path") ->
        Error.validation_error("choice condition contains invalid ref path", %{
          path: nested_path,
          segment: details.segment
        })

      String.contains?(error.message, "invalid ref") ->
        Error.validation_error("choice condition contains invalid ref", %{
          path: nested_path,
          type: details.type
        })

      String.contains?(error.message, "unsupported expression") ->
        Error.validation_error("choice condition contains unsupported expression", %{
          path: nested_path,
          expression: details.expression
        })

      true ->
        Error.validation_error("choice condition contains unsupported expression", %{
          path: path,
          expression: expression_kind(error)
        })
    end
  end

  defp expression_kind(_error), do: Function

  defp reverse_ok_list({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_ok_list({:error, error}), do: {:error, error}
end
