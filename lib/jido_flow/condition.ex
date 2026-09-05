defmodule Jido.Flow.Condition do
  @moduledoc """
  A closed, data-only condition used by a Flow choice.

  Comparison operators are `:eq`, `:neq`, `:lt`, `:lte`, `:gt`, `:gte`, and
  `:in`. Boolean operators are `:all`, `:any`, and `:not`.

  Conditions accept Flow input, context, and prior-result references.
  They do not accept arbitrary predicate functions. `:all` and `:any`
  short-circuit during execution.

  Every constructor returns `Jido.Expr`. The legacy Condition struct is an
  input form only; constructors convert it before it enters a Flow.
  All operation trees use the fixed Expr limits, including legacy input.
  Boolean operand types are checked only when the operand is evaluated.

      condition = Jido.Flow.Condition.eq(Jido.Flow.Ref.input(:status), :ready)
      {:ok, ^condition} = Jido.Flow.Condition.validate(condition, :flow)
  """

  alias Jido.Expr
  alias Jido.Flow.Ref
  alias Jido.Flow.Error
  alias Jido.Flow.Expression

  import Kernel, except: [in: 2]

  @comparison_operators [:eq, :neq, :lt, :lte, :gt, :gte, :in]
  @group_operators [:all, :any]
  @operators @comparison_operators ++ @group_operators ++ [:not]

  @typedoc "One supported Condition helper operator."
  @type operator :: :eq | :neq | :lt | :lte | :gt | :gte | :in | :all | :any | :not

  @schema Zoi.struct(
            __MODULE__,
            %{
              operator: Zoi.enum(@operators, description: "Condition operator"),
              operands: Zoi.list(Zoi.any(), description: "Condition operands")
            },
            coerce: true
          )

  @typedoc "Legacy construction input. Canonical conditions use `Jido.Expr`."
  @type t :: unquote(Zoi.type_spec(@schema))

  @typedoc "Accepted condition inputs, including strict Boolean references and expressions."
  @type input :: t() | Expr.t() | Ref.t() | boolean()

  @typedoc "A validated condition in the canonical Flow model."
  @type normalized :: Expr.t()

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Builds and validates a canonical condition from an operator and its operands."
  @spec new(operator(), list()) :: {:ok, normalized()} | {:error, Exception.t()}
  def new(operator, operands) do
    with :ok <- validate_operator(operator, "choice condition") do
      validate(%Expr{operator: operator, operands: operands}, :any)
    end
  end

  @doc "Validates and rebuilds one condition."
  @spec new(input()) :: {:ok, normalized()} | {:error, Exception.t()}
  def new(%__MODULE__{} = condition), do: validate(condition, :any)
  def new(%Expr{} = expression), do: validate(expression, :any)
  def new(%Ref{} = reference), do: validate(reference, :any)
  def new(value) when is_boolean(value), do: validate(value, :any)

  def new(_condition) do
    {:error,
     Error.validation_error("choice condition must be a Jido.Flow.Condition", %{path: []})}
  end

  @doc "Validates one condition for the specified reference scope."
  @spec validate(input(), Jido.Flow.Ref.scope()) :: {:ok, normalized()} | {:error, Exception.t()}
  def validate(condition, scope)
      when is_struct(condition, __MODULE__) or is_struct(condition, Expr) do
    with {:ok, expression} <- Expression.normalize(condition),
         :ok <- Expression.validate(expression, scope) do
      {:ok, expression}
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
  @spec new!(operator(), list()) :: normalized() | no_return()
  def new!(operator, operands) do
    case new(operator, operands) do
      {:ok, condition} -> condition
      {:error, error} -> raise error
    end
  end

  @doc "Builds an equality condition."
  @spec eq(Expression.t(), Expression.t()) :: normalized()
  def eq(left, right), do: new!(:eq, [left, right])

  @doc "Builds an inequality condition."
  @spec neq(Expression.t(), Expression.t()) :: normalized()
  def neq(left, right), do: new!(:neq, [left, right])

  @doc "Builds a less-than condition."
  @spec lt(Expression.t(), Expression.t()) :: normalized()
  def lt(left, right), do: new!(:lt, [left, right])

  @doc "Builds a less-than-or-equal condition."
  @spec lte(Expression.t(), Expression.t()) :: normalized()
  def lte(left, right), do: new!(:lte, [left, right])

  @doc "Builds a greater-than condition."
  @spec gt(Expression.t(), Expression.t()) :: normalized()
  def gt(left, right), do: new!(:gt, [left, right])

  @doc "Builds a greater-than-or-equal condition."
  @spec gte(Expression.t(), Expression.t()) :: normalized()
  def gte(left, right), do: new!(:gte, [left, right])

  @doc "Builds a list-membership condition."
  @spec Expression.t() in Expression.t() :: normalized()
  def left in right, do: new!(:in, [left, right])

  @doc "Builds a condition that requires all child conditions to be true."
  @spec all([Expression.t() | t()]) :: normalized()
  def all(conditions), do: new!(:all, conditions)

  @doc "Builds a condition that requires one child condition to be true."
  @spec any([Expression.t() | t()]) :: normalized()
  def any(conditions), do: new!(:any, conditions)

  @doc "Builds a condition that inverts one child condition."
  @spec not (Expression.t() | t()) :: normalized()
  def not condition, do: new!(:not, [condition])

  @doc false
  @spec to_expr(t()) :: {:ok, Expr.t()} | {:error, Exception.t()}
  def to_expr(%__MODULE__{operator: operator, operands: operands}) do
    with :ok <- validate_operator(operator, "choice condition") do
      {:ok, %Expr{operator: operator, operands: operands}}
    end
  end

  defp validate_operator(operator, _owner) when Kernel.in(operator, @operators), do: :ok

  defp validate_operator(_operator, owner) do
    {:error, Error.validation_error("unsupported #{owner} operator", %{path: []})}
  end

  defp condition_owner(:iterate_completion), do: "iterator completion condition"
  defp condition_owner(_scope), do: "choice condition"
end
