defmodule Jido.Expr do
  @moduledoc """
  Portable expressions and a shared, restricted helper DSL.

  Expressions store fixed operators and data, never executable callbacks.
  Host packages can share the same syntax through `parse/2`, then supply
  their own reference parser, validator, and resolver. This module does not
  depend on a host package or a reference namespace.

  ## Author expressions

      import Jido.Expr, only: [expr: 1]

      calculation = expr(2 * 3 + 1)
      {:ok, 7} = Jido.Expr.evaluate(calculation)

  Use `^value` in `expr/1` to insert a prebuilt value or host reference from
  an Elixir variable. This is a trusted source-code boundary, not stored
  expression syntax. Application calls, including calls inside a pin, are
  rejected. A host parser does not accept pins by default.

  The grammar supports `==`, `!=`, `<`, `<=`, `>`, `>=`, `in`, `and`, `or`,
  `not`, `+`, binary and unary `-`, `*`, `/`, `div/2`, `rem/2`, `min/2`,
  `max/2`, `abs/1`, and `<>`. Boolean operators require Boolean operands and
  short-circuit. Ordering accepts two numbers or two binaries. Arithmetic
  accepts numbers; `div` and `rem` require integers. Concatenation accepts
  binaries. There is no implicit conversion. `in` requires a proper list.
  Equality uses Elixir `==`, including numeric equality across integer and
  float types. Parentheses use normal Elixir precedence.

  The condition aliases `eq`, `neq`, `lt`, `lte`, `gt`, `gte`, `all`, and
  `any` are also accepted. `all` and `any` take one non-empty operand list.

  ## Resource limits

  `parse/2`, `validate/2`, and `evaluate/2` accept positive integer limits:

  * `:max_depth` defaults to 64 nested data or expression levels.
  * `:max_nodes` defaults to 10,000 visited values, including resolved data
    and comparison work during evaluation.
  * `:max_binary_bytes` defaults to 1,048,576 cumulative bytes in visited
    binaries and generated results.
  * `:max_integer_bits` defaults to 4,096 bits in each integer magnitude.

  Limits cannot exceed 1,048,576,000. `:max_integer_bits` has a lower maximum
  of 1,048,576 to keep the limit check itself bounded.

  Limits apply to each call. Evaluation checks a Boolean group's operand-list
  shape within the remaining node limit before it short-circuits. A group
  with too many operands can fail even when its first operand determines the
  result. Skipped operands are not resolved or evaluated. Validation checks
  the complete tree. Resolve and validation callbacks belong to trusted host
  code and must themselves be bounded.
  Resolved values are checked as data and are never evaluated as expressions.
  """

  alias Jido.Expr.{Error, Parser, Runtime}

  @operators [
    :eq,
    :neq,
    :lt,
    :lte,
    :gt,
    :gte,
    :in,
    :all,
    :any,
    :not,
    :add,
    :subtract,
    :multiply,
    :divide,
    :negate,
    :div,
    :rem,
    :min,
    :max,
    :abs,
    :concat
  ]

  @enforce_keys [:operator, :operands]
  defstruct [:operator, :operands]

  @typedoc "One fixed operation with data or nested expression operands."
  @type t :: %__MODULE__{operator: atom(), operands: [term()]}

  @typedoc "Expression limits and trusted host integration callbacks."
  @type options :: keyword()

  @doc "Returns the closed list of canonical operator atoms."
  @spec operators() :: [atom()]
  def operators, do: @operators

  @doc "Constructs an expression after checking its operator and operand arity."
  @spec new(atom(), [term()]) :: {:ok, t()} | {:error, Error.t()}
  def new(operator, operands) do
    cond do
      operator not in @operators ->
        {:error, %Error{reason: :unknown_operator, operator: safe_operator(operator)}}

      not valid_arity?(operator, operands) ->
        {:error, %Error{reason: :invalid_arity, operator: operator}}

      true ->
        {:ok, %__MODULE__{operator: operator, operands: operands}}
    end
  end

  @doc "Constructs an expression, or raises `Jido.Expr.Error`."
  @spec new!(atom(), [term()]) :: t()
  def new!(operator, operands), do: unwrap!(new(operator, operands))

  @doc """
  Parses quoted source with the shared, inert expression grammar.

  `:leaf_parser` can be a function that accepts an unknown AST node and
  returns `{:ok, host_value}`, `:error`, or `{:error, error}`. The fixed
  operator grammar takes precedence. Host errors pass through unchanged;
  a returned `Jido.Expr.Error` path is relative to the parsed location.
  The callback is trusted authoring code, not stored in the result. Neither
  this function nor its default grammar evaluates source.
  """
  @spec parse(Macro.t(), options()) :: {:ok, term()} | {:error, term()}
  def parse(ast, options \\ []), do: Parser.parse(ast, options)

  @doc "Parses quoted source, or raises on a parse failure."
  @spec parse!(Macro.t(), options()) :: term()
  def parse!(ast, options \\ []), do: unwrap!(parse(ast, options))

  @doc "Builds expression data from source; `^variable` inserts trusted host data."
  @spec expr(Macro.t()) :: Macro.t()
  defmacro expr(ast), do: Parser.expand!(ast)

  @doc """
  Validates a complete expression or data tree without running operations.

  A `:validate_leaf` callback can accept a host struct and return `:ok` or
  `{:error, error}`. Unknown structs otherwise fail validation. Callback
  errors pass through unchanged; expression errors include their tree path.
  An arity-two callback also receives the current path. A returned
  `Jido.Expr.Error` path is relative to that location.
  """
  @spec validate(term(), options()) :: :ok | {:error, term()}
  def validate(value, options \\ []), do: Runtime.validate(value, options)

  @doc """
  Evaluates an expression or data tree with bounded fixed operations.

  A `:resolve` callback accepts a host struct and returns `{:ok, value}` or
  `{:error, error}`. Unknown structs otherwise fail. Returned data is not
  interpreted as expression code. Host errors pass through unchanged.
  An arity-two callback also receives the current path. A returned
  `Jido.Expr.Error` path is relative to that location.
  """
  @spec evaluate(term(), options()) :: {:ok, term()} | {:error, term()}
  def evaluate(value, options \\ []), do: Runtime.evaluate(value, options)

  defp valid_arity?(operator, [_]) when operator in [:not, :negate, :abs], do: true

  defp valid_arity?(operator, [_ | _] = operands) when operator in [:all, :any],
    do: not List.improper?(operands)

  defp valid_arity?(operator, [_, _]) when operator not in [:not, :negate, :abs, :all, :any],
    do: true

  defp valid_arity?(_, _), do: false

  defp safe_operator(operator) when is_atom(operator), do: operator
  defp safe_operator(_), do: nil
  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, error}), do: raise(error)
end
