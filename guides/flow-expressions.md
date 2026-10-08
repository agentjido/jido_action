# Expressions

`Jido.Expr` adds small, portable calculations and conditions to Flow fields.
An expression contains a fixed set of operators and data. It never contains
executable callbacks.

Use an expression for a short calculation or an obvious condition. Use an
inline Action or a named Action when the operation needs an explanation,
application calls, or side effects.

## Calculate At The Point Of Use

The module DSL reads its field values before Elixir evaluates them. You do not
need an import or an `expr(...)` wrapper in those fields; the wrapper is
optional. Normal Elixir inside an inline Action body is unchanged.

```elixir
defmodule ExprGuide.Invoice do
  use Jido.Flow, name: "expression_invoice"

  flow do
    step "normalize", name <- input(:name) do
      {:ok, %{name: String.trim(name)}}
    end

    output %{
      total: input(:quantity) * input(:price),
      limit: min(input(:requested), input(:maximum)),
      eligible: input(:enabled) and not context(:paused),
      message: expr("Hello, " <> result("normalize", :name) <> "!")
    }
  end
end

{:ok, %{total: 6, limit: 5, eligible: true, message: "Hello, Ada!"}} =
  Jido.Exec.run(
    ExprGuide.Invoice,
    %{name: " Ada ", quantity: 2, price: 3, requested: 8, maximum: 5, enabled: true},
    %{paused: false}
  )
```

The same syntax works in Step and Subflow params, Choice conditions and
params, Map and Reduce fields, Iterate State, `update`, and `while`, Dispatch
params, and Flow output. Each field keeps its reference scope and result-shape
rules.

Inline Step binding sources are the exception. The right side of `<-` accepts
references and data only. Bind the data and calculate in the body. See
[Inline Steps](inline-actions.md).

## Complete Operation List

| Syntax | Runtime operator | Rules |
| --- | --- | --- |
| `==`, `!=` | `:==`, `:!=` | Elixir equality: `1 == 1.0`; atoms and strings differ. |
| `<`, `<=`, `>`, `>=` | `:<`, `:<=`, `:>`, `:>=` | Native Elixir term order, including mixed types. |
| `in` | `:in` | Right operand is a proper list; membership uses strict `===`. |
| `and`, `or` | `:and`, `:or` | Boolean left operand; short-circuit or return the right operand unchanged. |
| `not` | `:not` | Boolean operand. |
| `+`, binary `-`, `*`, `/` | `:+`, `:-`, `:*`, `:/` | Numbers only; `/` returns a float. |
| Unary `-` | `:-` | A number. |
| `div`, `rem` | `:div`, `:rem` | Integers; division truncates toward zero; remainder has the dividend's sign. |
| `min`, `max` | `:min`, `:max` | Native Elixir term order; preserve the selected value and type. |
| `abs` | `:abs` | A number. |
| `<>` | `:<>` | Binaries only; no implicit conversion. |

Precedence and grouping follow Elixir. `a and b and c` works without
parentheses; parentheses change grouping as they do in Elixir. Literals,
nested maps and lists, and reference helpers are valid operands.

These forms are rejected: `&&`, `||`, `!`, `===`, `!==`, unary `+`, power,
rounding, string interpolation, ranges, tuples, keyword lists, conditional
statements, assignment, pipes, function calls, module attributes, and
variables from the surrounding module. The fixed helpers in the table are the
only function-shaped operations.

## Conditions And Missing Values

A condition must evaluate to a Boolean. `condition: input(:enabled)` and
`while not state(:done)` are valid. A present `nil`, number, or string fails
at runtime. Use a required `Zoi.boolean()` field in the Flow input schema, the
producing Action's output schema, or the Iterate State schema when the
contract needs a Boolean.

`and` and `or` can return their right operand unchanged, as in Elixir:
`false and 1` returns `false`, and `true and 1` returns `1`. A condition
rejects the result of `true and 1`, but `%{value: true and 1}` is valid output
data. `(true and 1) and false` fails because the outer left operand is not a
Boolean.

`false and input(:missing)` skips its second operand, and `true or 1 / 0 > 0`
succeeds. This does not make producer components lazy. Every result reference
is still a static dependency, including references in skipped operands.
Validation also checks data, tree shape, and reference scope in skipped
operands.

A missing reference is an error. A present `nil` is a value:
`input(:value) == nil` tests that value, but it does not catch a missing key.

## Data Definitions And Direct Construction

In map definitions, build operations with `Jido.Expr.new/2` or
`Jido.Expr.new!/2`. Both check the operator and arity. `Jido.Flow.new/1` then
validates the complete expression and its reference scopes.

The `expr/1` macro accepts the same operation syntax. Insert a prebuilt
reference or value from an Elixir variable with `^variable`. Pins are a
trusted source-code feature. Stored documents and DSL fields do not accept
them. Calls inside a pin are rejected; compute the value before the macro.

```elixir
import Jido.Expr, only: [expr: 1]
alias Jido.Flow.Ref
quantity = Ref.input(:quantity)
price = Ref.input(:price)
total = expr(^quantity * ^price)
true = total == Jido.Expr.new!(:*, [quantity, price])

{:ok, built} =
  Jido.Flow.new(%{
    output: %{total: total},
    components: [
      %{
        kind: :step,
        name: "normalize",
        action: ExprGuide.Invoice.step_action("normalize"),
        params: %{name: Ref.input(:name)}
      }
    ],
    name: "expression_data"
  })

{:ok, %{total: 6}} = Jido.Exec.run(built, %{name: "Ada", quantity: 2, price: 3})
```

A condition in a map definition is a Boolean, a reference, or an expression:

```elixir
eligible = Jido.Expr.new!(:>=, [Ref.input(:score), 10])
```

`Jido.Flow.Condition` no longer exists. Replace its constructors with
`Jido.Expr.new/2` or `Jido.Expr.new!/2`. Do not use `Jido.Expr.validate/2` as
a replacement for Flow validation; it does not check Flow reference scopes.

## Stored JSON

`Jido.Flow.Codec` stores each operation under a `$expr` tag. A document with
operations uses version 2:

```elixir
{:ok, document, registry} = Jido.Flow.Codec.encode(built)
2 = document["version"]
json = JSON.encode!(document)
{:ok, restored} = Jido.Flow.Codec.decode(JSON.decode!(json), registry)
true = restored == built
{:ok, %{total: 6}} = Jido.Exec.run(restored, %{name: "Ada", quantity: 2, price: 3})
```

See [Store Flows As JSON](flow-storage.md) for document versions, tags,
Registry identifiers, and storage limits.

## Errors And Limits

Generic failures use `Jido.Expr.Error`. Flow converts expression failures to
its structured errors. Runtime errors include `operator`, `reason`,
`expression_path`, and `retry: false`. Reference failures keep the reference
`path` and add the expression location. Error metadata does not include
operand values or unrelated context.

Each complete operation tree, including a condition, has these limits:

- 64 levels;
- 10,000 visited values;
- 1,048,576 cumulative binary bytes; and
- 4,096 bits per integer magnitude.

The limits apply at construction and evaluation. Evaluation also counts
resolved data, comparison work, and generated values. A Boolean tree must fit
within the node limit even when evaluation skips an operand.

Plain Flow data around an operation does not count toward that budget. Stored
documents also have [Codec limits](flow-storage.md#validation-and-limits).

## Elixir Conformance

Supported syntax behaves like native Elixir for the supported data. For
example, `1 in [1.0]` is false, and `true and 123` returns `123`. Ordering and
`min` or `max` accept mixed portable values and use term order.

The test suite includes `test/jido_expr/elixir_conformance_test.exs`. It lists
every accepted spelling and compares results with native Elixir.

## Advanced: Reuse The Syntax In A Host DSL

`Jido.Expr` does not depend on Flow. Another data-only DSL can call
`Jido.Expr.parse/2` with a small parser for its own reference forms. The
shared parser owns all operators; the host cannot add operators. The host
validates its reference scope and supplies values at evaluation. The callbacks
belong to trusted host code and are never stored in an expression.

```elixir
defmodule ExprGuide.Field do
  defstruct [:key]
end

defmodule ExprGuide.Host do
  defmacro expr(ast) do
    ast
    |> Jido.Expr.parse!(leaf_parser: &__MODULE__.parse_reference/1)
    |> Macro.escape()
  end

  def parse_reference({:field, _, [key]}) when is_atom(key),
    do: {:ok, struct(ExprGuide.Field, key: key)}

  def parse_reference(_), do: :error

  def evaluate(expression, values) do
    Jido.Expr.evaluate(expression,
      resolve: fn %ExprGuide.Field{key: key} ->
        case Map.fetch(values, key) do
          {:ok, value} -> {:ok, value}
          :error -> {:error, %Jido.Expr.Error{reason: :missing_field}}
        end
      end
    )
  end
end

defmodule ExprGuide.HostExample do
  require ExprGuide.Host
  def rule, do: ExprGuide.Host.expr(field(:count) * 2 >= 8 and not field(:paused))
end

:ok =
  Jido.Expr.validate(ExprGuide.HostExample.rule(),
    validate_leaf: fn %{__struct__: ExprGuide.Field} -> :ok end
  )

{:ok, true} = ExprGuide.Host.evaluate(ExprGuide.HostExample.rule(), %{count: 4, paused: false})
```

A host can use an arity-two validator or resolver to receive the expression
path. A returned `Jido.Expr.Error` path is relative to that location. Other
host errors pass through unchanged. Resolved values are treated as data, never
as new expressions. Host callbacks must be bounded, accept only the host's
documented reference forms, and not run application work during parsing or
validation.

For a complete host that also compiles inline Action bodies, see
[Building DSLs With Inline Actions](building-dsls-with-inline-actions.md).
