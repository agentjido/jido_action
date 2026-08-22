defmodule Jido.Flow.Condition do
  @moduledoc """
  A closed, data-only condition used by a Flow choice.

  Comparison operators are `:eq`, `:neq`, `:lt`, `:lte`, `:gt`, `:gte`, and
  `:in`. Boolean operators are `:all`, `:any`, and `:not`.

  Conditions accept Flow input, context, value, and prior-result references.
  They do not accept arbitrary predicate functions. `:all` and `:any`
  short-circuit during execution.
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

  @doc false
  @spec validate(t(), Jido.Flow.Ref.scope()) :: {:ok, t()} | {:error, Exception.t()}
  def validate(%__MODULE__{} = condition, scope) do
    with :ok <- validate_operator(condition.operator),
         :ok <- validate_arity(condition.operator, condition.operands),
         {:ok, operands} <- normalize_operands(condition.operator, condition.operands, scope) do
      {:ok, %{condition | operands: operands}}
    end
  end

  def validate(_condition, _scope) do
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

  @doc "Builds an equality condition."
  def eq(left, right), do: new!(:eq, [left, right])

  @doc "Builds an inequality condition."
  def neq(left, right), do: new!(:neq, [left, right])

  @doc "Builds a less-than condition."
  def lt(left, right), do: new!(:lt, [left, right])

  @doc "Builds a less-than-or-equal condition."
  def lte(left, right), do: new!(:lte, [left, right])

  @doc "Builds a greater-than condition."
  def gt(left, right), do: new!(:gt, [left, right])

  @doc "Builds a greater-than-or-equal condition."
  def gte(left, right), do: new!(:gte, [left, right])

  @doc "Builds a list-membership condition."
  def unquote(:in)(left, right), do: new!(:in, [left, right])

  @doc "Builds a condition that requires all child conditions to be true."
  def all(conditions), do: new!(:all, conditions)

  @doc "Builds a condition that requires one child condition to be true."
  def any(conditions), do: new!(:any, conditions)

  @doc "Builds a condition that inverts one child condition."
  def not condition, do: new!(:not, [condition])

  @doc false
  @spec result_deps(t()) :: [String.t()]
  def result_deps(%__MODULE__{} = condition) do
    condition
    |> collect_result_deps()
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

  defp validate_arity(operator, operands) when is_list(operands) do
    if List.improper?(operands) do
      {:error,
       Error.validation_error("choice condition operands must be a proper list", %{path: []})}
    else
      validate_proper_arity(operator, operands)
    end
  end

  defp validate_arity(_operator, _operands) do
    {:error, Error.validation_error("choice condition operands must be a list", %{path: []})}
  end

  defp validate_proper_arity(operator, operands)
       when Kernel.in(operator, @comparison_operators) do
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

  defp validate_proper_arity(operator, operands) when Kernel.in(operator, @group_operators) do
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

  defp validate_proper_arity(:not, operands) do
    if length(operands) == 1 do
      :ok
    else
      {:error,
       Error.validation_error("choice condition :not must have exactly 1 condition", %{path: []})}
    end
  end

  defp normalize_operands(operator, operands) when Kernel.in(operator, @comparison_operators) do
    normalize_operands(operator, operands, :flow)
  end

  defp normalize_operands(operator, operands)
       when Kernel.in(operator, @group_operators) or operator == :not do
    normalize_operands(operator, operands, :flow)
  end

  defp normalize_operands(operator, operands, scope)
       when Kernel.in(operator, @comparison_operators) do
    operands
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {operand, index}, {:ok, acc} ->
      case normalize_expression(operand, [index], scope) do
        {:ok, operand} -> {:cont, {:ok, [operand | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> reverse_ok_list()
  end

  defp normalize_operands(operator, operands, scope)
       when Kernel.in(operator, @group_operators) or operator == :not do
    operands
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {operand, index}, {:ok, acc} ->
      case validate(operand, scope) do
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

  defp normalize_expression(expression, path, scope) do
    with {:ok, expression} <- Node.normalize_expression(expression),
         :ok <- Node.validate_expression(expression, scope),
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

    case Node.expression_error_kind(error) do
      :invalid_scope ->
        Error.validation_error(
          "flow expression contains a scoped ref outside its valid scope",
          %{path: nested_path, ref_type: details.ref_type, scope: details.scope}
        )

      :invalid_ref_path ->
        Error.validation_error("choice condition contains invalid ref path", %{
          path: nested_path,
          segment: details.segment
        })

      :invalid_ref ->
        Error.validation_error("choice condition contains invalid ref", %{
          path: nested_path,
          type: details.type
        })

      :improper_list ->
        Error.validation_error("choice condition expression must be a proper list", %{
          path: nested_path
        })

      :unsupported_expression ->
        Error.validation_error("choice condition contains unsupported expression", %{
          path: nested_path,
          expression: details.expression
        })

      :other ->
        Error.validation_error("choice condition contains unsupported expression", %{
          path: path,
          expression: expression_kind(error)
        })
    end
  end

  defp collect_result_deps(%__MODULE__{operator: operator, operands: operands})
       when Kernel.in(operator, @comparison_operators) do
    Enum.flat_map(operands, &Node.collect_result_refs/1)
  end

  defp collect_result_deps(%__MODULE__{operands: operands}) do
    Enum.flat_map(operands, &collect_result_deps/1)
  end

  defp expression_kind(_error), do: Function

  defp reverse_ok_list({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_ok_list({:error, error}), do: {:error, error}
end
