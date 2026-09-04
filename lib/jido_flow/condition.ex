defmodule Jido.Flow.Condition do
  @moduledoc """
  A closed, data-only condition used by a Flow choice.

  Comparison operators are `:eq`, `:neq`, `:lt`, `:lte`, `:gt`, `:gte`, and
  `:in`. Boolean operators are `:all`, `:any`, and `:not`.

  Conditions accept Flow input, context, and prior-result references.
  They do not accept arbitrary predicate functions. `:all` and `:any`
  short-circuit during execution.

      condition = Jido.Flow.Condition.eq(Jido.Flow.Ref.input(:status), :ready)
      {:ok, ^condition} = Jido.Flow.Condition.validate(condition, :flow)
  """

  alias Jido.Action
  alias Jido.Expr
  alias Jido.Flow.Ref
  alias Jido.Flow.Error
  alias Jido.Flow.Expression

  import Kernel, except: [in: 2]

  @comparison_operators [:eq, :neq, :lt, :lte, :gt, :gte, :in]
  @group_operators [:all, :any]
  @operators @comparison_operators ++ @group_operators ++ [:not]

  @type operator :: :eq | :neq | :lt | :lte | :gt | :gte | :in | :all | :any | :not

  @schema Zoi.struct(
            __MODULE__,
            %{
              operator: Zoi.enum(@operators, description: "Condition operator"),
              operands: Zoi.list(Zoi.any(), description: "Condition operands")
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @typedoc "Accepted condition inputs, including strict Boolean references and expressions."
  @type input :: t() | Expr.t() | Ref.t() | boolean()

  @typedoc "A validated condition in the canonical Flow model."
  @type normalized :: t() | Expr.t()

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Builds and validates a condition from an operator and its operands."
  @spec new(operator(), list()) :: {:ok, t()} | {:error, Exception.t()}
  def new(operator, operands) do
    with :ok <- validate_operator(operator, "choice condition"),
         :ok <- validate_arity(operator, operands, "choice condition"),
         {:ok, operands} <- normalize_operands(operator, operands) do
      {:ok, %__MODULE__{operator: operator, operands: operands}}
    end
  end

  @doc "Validates and rebuilds one condition."
  @spec new(input()) :: {:ok, normalized()} | {:error, Exception.t()}
  def new(%__MODULE__{} = condition), do: new(condition.operator, condition.operands)
  def new(%Expr{} = expression), do: validate(expression, :any)
  def new(%Ref{} = reference), do: validate(reference, :any)
  def new(value) when is_boolean(value), do: validate(value, :any)

  def new(_condition) do
    {:error,
     Error.validation_error("choice condition must be a Jido.Flow.Condition", %{path: []})}
  end

  @doc "Validates one condition for the specified reference scope."
  @spec validate(input(), Jido.Flow.Ref.scope()) :: {:ok, normalized()} | {:error, Exception.t()}
  def validate(%__MODULE__{} = condition, scope) do
    owner = condition_owner(scope)

    with :ok <- validate_operator(condition.operator, owner),
         :ok <- validate_arity(condition.operator, condition.operands, owner),
         {:ok, operands} <-
           normalize_operands(condition.operator, condition.operands, scope, owner) do
      {:ok, %{condition | operands: operands}}
    end
  end

  def validate(%Expr{} = expression, scope) do
    with {:ok, expression} <- Expression.normalize(expression),
         :ok <- Expression.validate(expression, scope) do
      canonical_condition(expression, scope)
    end
  end

  def validate(%Ref{} = reference, scope), do: validate(Expr.new!(:all, [reference]), scope)
  def validate(value, scope) when is_boolean(value), do: validate(Expr.new!(:all, [value]), scope)

  def validate(_condition, scope) do
    {:error,
     Error.validation_error("#{condition_owner(scope)} must be a Jido.Flow.Condition", %{
       path: []
     })}
  end

  @doc false
  @spec new!(operator(), list()) :: t() | no_return()
  def new!(operator, operands) do
    case new(operator, operands) do
      {:ok, condition} -> condition
      {:error, error} -> raise error
    end
  end

  @doc "Builds an equality condition."
  @spec eq(Expression.t(), Expression.t()) :: t()
  def eq(left, right), do: new!(:eq, [left, right])

  @doc "Builds an inequality condition."
  @spec neq(Expression.t(), Expression.t()) :: t()
  def neq(left, right), do: new!(:neq, [left, right])

  @doc "Builds a less-than condition."
  @spec lt(Expression.t(), Expression.t()) :: t()
  def lt(left, right), do: new!(:lt, [left, right])

  @doc "Builds a less-than-or-equal condition."
  @spec lte(Expression.t(), Expression.t()) :: t()
  def lte(left, right), do: new!(:lte, [left, right])

  @doc "Builds a greater-than condition."
  @spec gt(Expression.t(), Expression.t()) :: t()
  def gt(left, right), do: new!(:gt, [left, right])

  @doc "Builds a greater-than-or-equal condition."
  @spec gte(Expression.t(), Expression.t()) :: t()
  def gte(left, right), do: new!(:gte, [left, right])

  @doc "Builds a list-membership condition."
  @spec Expression.t() in Expression.t() :: t()
  def left in right, do: new!(:in, [left, right])

  @doc "Builds a condition that requires all child conditions to be true."
  @spec all([input()]) :: t()
  def all(conditions), do: new!(:all, conditions)

  @doc "Builds a condition that requires one child condition to be true."
  @spec any([input()]) :: t()
  def any(conditions), do: new!(:any, conditions)

  @doc "Builds a condition that inverts one child condition."
  @spec not input() :: t()
  def not condition, do: new!(:not, [condition])

  @doc false
  @spec result_deps(normalized()) :: [String.t()]
  def result_deps(%__MODULE__{} = condition) do
    condition
    |> collect_result_deps()
    |> Enum.uniq()
    |> Enum.sort()
  end

  def result_deps(expression),
    do: Expression.result_refs(expression) |> Enum.uniq() |> Enum.sort()

  @doc false
  @spec to_map(normalized()) :: map()
  def to_map(%__MODULE__{operator: operator, operands: operands}) do
    %{
      operator: operator,
      operands:
        Enum.map(operands, fn
          %__MODULE__{} = condition -> to_map(condition)
          expression -> Expression.to_map(expression)
        end)
    }
  end

  def to_map(%Expr{} = expression), do: Expression.to_map(expression)

  defp validate_operator(operator, _owner) when Kernel.in(operator, @operators), do: :ok

  defp validate_operator(_operator, owner) do
    {:error, Error.validation_error("unsupported #{owner} operator", %{path: []})}
  end

  defp validate_arity(operator, operands, owner) when is_list(operands) do
    if List.improper?(operands) do
      {:error, Error.validation_error("#{owner} operands must be a proper list", %{path: []})}
    else
      validate_proper_arity(operator, operands, owner)
    end
  end

  defp validate_arity(_operator, _operands, owner) do
    {:error, Error.validation_error("#{owner} operands must be a list", %{path: []})}
  end

  defp validate_proper_arity(operator, operands, owner)
       when Kernel.in(operator, @comparison_operators) do
    if length(operands) == 2 do
      :ok
    else
      {:error,
       Error.validation_error(
         "#{owner} #{inspect(operator)} must have exactly 2 operands",
         %{
           path: []
         }
       )}
    end
  end

  defp validate_proper_arity(operator, operands, owner)
       when Kernel.in(operator, @group_operators) do
    if operands == [] do
      {:error,
       Error.validation_error(
         "#{owner} #{inspect(operator)} must have at least 1 condition",
         %{
           path: []
         }
       )}
    else
      :ok
    end
  end

  defp validate_proper_arity(:not, operands, owner) do
    if length(operands) == 1 do
      :ok
    else
      {:error, Error.validation_error("#{owner} :not must have exactly 1 condition", %{path: []})}
    end
  end

  defp normalize_operands(operator, operands) when Kernel.in(operator, @comparison_operators) do
    normalize_operands(operator, operands, :any, "flow condition")
  end

  defp normalize_operands(operator, operands)
       when Kernel.in(operator, @group_operators) or operator == :not do
    normalize_operands(operator, operands, :any, "flow condition")
  end

  defp normalize_operands(operator, operands, scope, owner)
       when Kernel.in(operator, @comparison_operators) do
    operands
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {operand, index}, {:ok, acc} ->
      case normalize_expression(operand, [index], scope, owner) do
        {:ok, operand} -> {:cont, {:ok, [operand | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> reverse_ok_list()
  end

  defp normalize_operands(operator, operands, scope, owner)
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
              "#{owner} #{inspect(operator)} contains an invalid child condition",
              %{
                path: [index]
              }
            )}}
      end
    end)
    |> reverse_ok_list()
  end

  defp normalize_expression(expression, path, scope, owner) do
    with {:ok, expression} <- Expression.normalize(expression),
         :ok <- Expression.validate(expression, scope),
         :ok <- validate_static_expression(expression, owner) do
      {:ok, expression}
    else
      {:error, error} -> {:error, translate_expression_error(error, path, owner)}
    end
  end

  defp validate_static_expression(expression, owner) do
    case Action.validate_static_data(expression) do
      :ok ->
        :ok

      {:error, _reason} ->
        {:error, Error.validation_error("unsupported #{owner} expression")}
    end
  end

  defp translate_expression_error(error, path, owner) do
    details = Map.get(error, :details, %{})
    nested_path = path ++ Map.get(details, :path, [])

    case Expression.error_kind(error) do
      :invalid_scope ->
        Error.validation_error(
          "flow expression contains a scoped ref outside its valid scope",
          %{path: nested_path, ref_type: details.ref_type, scope: details.scope}
        )

      :invalid_ref_path ->
        Error.validation_error("#{owner} contains invalid ref path", %{
          path: nested_path,
          segment: details.segment
        })

      :invalid_ref ->
        Error.validation_error("#{owner} contains invalid ref", %{
          path: nested_path,
          type: details.ref_type
        })

      :improper_list ->
        Error.validation_error("#{owner} expression must be a proper list", %{
          path: nested_path
        })

      :unsupported_expression ->
        Error.validation_error("#{owner} contains unsupported expression", %{
          path: nested_path,
          expression: details.expression
        })

      :other ->
        Error.validation_error("#{owner} contains unsupported expression", %{
          path: path,
          expression: expression_kind(error)
        })
    end
  end

  defp collect_result_deps(%__MODULE__{operator: operator, operands: operands})
       when Kernel.in(operator, @comparison_operators) do
    Enum.flat_map(operands, &Expression.result_refs/1)
  end

  defp collect_result_deps(%__MODULE__{operands: operands}) do
    Enum.flat_map(operands, &collect_result_deps/1)
  end

  defp collect_result_deps(expression), do: Expression.result_refs(expression)

  defp expression_kind(_error), do: Function

  # Keep old condition shapes stable, while a single Boolean reference/literal
  # uses the shared evaluator for its strict runtime type check.
  defp canonical_condition(%Expr{operator: :all, operands: [%Ref{}]} = expression, _scope),
    do: {:ok, expression}

  defp canonical_condition(%Expr{operator: :all, operands: [value]} = expression, _scope)
       when is_boolean(value), do: {:ok, expression}

  defp canonical_condition(%Expr{operator: operator, operands: operands}, scope)
       when Kernel.in(operator, @operators),
       do: validate(%__MODULE__{operator: operator, operands: operands}, scope)

  defp canonical_condition(expression, _scope), do: {:ok, expression}

  defp condition_owner(:iterate_completion), do: "iterator completion condition"
  defp condition_owner(_scope), do: "choice condition"

  defp reverse_ok_list({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_ok_list({:error, error}), do: {:error, error}
end
