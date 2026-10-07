# Expressions In Flows And Host DSLs

`Jido.Expr` adds small, portable calculations to `jido_action` v3. The API is
available in `3.0.0-beta.6` or later.

Use an expression for a short calculation or an obvious condition. Use an
inline Action or a named Action when the operation needs an explanation,
application calls, or side effects. Keep a named Action for custom validation
or lifecycle hooks.

## Calculate At The Point Of Use

Flow captures its data fields before Elixir evaluates them. No import or
`expr(...)` wrapper is required in those fields. The wrapper is optional.
Normal Elixir inside an inline Action body is unchanged.

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
params, Map and Reduce fields, Iterate State and conditions, Dispatch params,
and Flow output. Each field keeps its existing reference scope and result-shape
rules. A normal Flow output is still a map.
The [Flow inline syntax](inline-actions.md) supplies direct bodies for Step.
These bodies compile to ordinary Action targets. Binding sources use direct
references or data. Bodies use normal Elixir and own calculations. Advanced
components use Action modules.

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

Parentheses use normal Elixir precedence. Build more than two Boolean tests as
an explicit tree of binary `and` or `or` operations. Portable literals, nested
maps and lists, and reference helpers remain valid.

There is no `&&`, `||`, `!`, `===`, `!==`, power, rounding, interpolation,
range, unary `+`, conditional statement, assignment, pipe, function call, or custom
guard system. The fixed helpers above are the only function-shaped
operations. Expressions are not `Jido.Instruction` targets.

## Boolean Conditions And Missing Values

`condition: input(:enabled)` and `while not state(:done)` are valid. Their
evaluated values must be Boolean. A present `nil`, number, or string fails.
Use a Boolean schema when the input contract requires a Boolean field.

`false and input(:missing)` skips its second operand. `true or 1 / 0 > 0`
also succeeds. This does not make producer Steps lazy: every result reference
remains a static dependency, including references in skipped operands.

Binary Boolean expressions preserve native grouping. `false and 1` returns
`false`; `true and 1` returns `1`. `(true and 1) and false` fails because the
outer left operand is not Boolean. A Flow condition rejects the result of
`true and 1`, but `%{value: true and 1}` is valid output data. Construction
checks data, tree shape, and reference scope even in skipped operands.

A missing reference is an error. A present `nil` is a value: `input(:value)
== nil` tests that value, but does not catch a missing key. Exact map keys
take priority; an atom path can fall back to its string spelling. A string
path does not create or select an atom key.

## Data Definitions And Direct Construction

Use `Jido.Expr.new!/2` for runtime operator data. Its non-raising `new/2`
checks the operator and arity. Flow definitions then validate the complete
expression and its reference scopes.

The standalone `expr/1` macro uses the same operation syntax. Insert a
prebuilt reference or value with `^variable`. This is a trusted source-code
feature, not syntax accepted from stored documents or inside Flow fields.
Calls inside a pin are rejected; compute a value before the macro if needed.

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

Use `Jido.Expr` for conditions and Boolean parameter or output values:

```elixir
eligible = Jido.Expr.new!(:>=, [Ref.input(:score), 10])
```

The V3 beta no longer provides `Jido.Flow.Condition` or accepts its records.
Replace its constructors with `Jido.Expr.new/2` or `Jido.Expr.new!/2`.
Use `Jido.Expr` for comparison and Boolean operations.
Expr construction checks the operator and arity; Flow definitions validate
the full expression, portable values, and reference scope. Do not use
`Jido.Expr.validate/2` as a replacement for Flow-specific validation.

## Stored JSON

```elixir
{:ok, document, registry} = Jido.Flow.Codec.encode(built)
2 = document["version"]
json = JSON.encode!(document)
{:ok, restored} = Jido.Flow.Codec.decode(JSON.decode!(json), registry)
true = restored == built
{:ok, %{total: 6}} = Jido.Exec.run(restored, %{name: "Ada", quantity: 2, price: 3})
```

See [Store Flows As JSON](flow-storage.md) for document versions, operation
tags, Registry IDs, and storage limits.

## Reuse The Syntax In A Host DSL

The helper does not depend on Flow. A host calls `Jido.Expr.parse/2` with a
small parser for its reference forms. The shared parser owns all operators;
the host does not copy or replace them. The host then validates its reference
scope and supplies values at evaluation. The callbacks belong to trusted
host code and are never stored in an expression.

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

:ok = Jido.Expr.validate(ExprGuide.HostExample.rule(),
  validate_leaf: fn %{__struct__: ExprGuide.Field} -> :ok end)
{:ok, true} = ExprGuide.Host.evaluate(ExprGuide.HostExample.rule(), %{count: 4, paused: false})
```

A host can use an arity-two validator or resolver to receive the expression
path. A returned `Jido.Expr.Error` path is relative to that location. Other
host errors pass through unchanged. Reference values are treated as data,
never as new expression instructions. Host callbacks must be bounded and
must accept only the host's documented reference forms. Parsing and
validation must not run application work. The API does not add a custom
operator registry or automatically integrate another Jido package.

For a complete host that also compiles inline Action bodies, see
[Build A Non-Flow Host](building-dsls-with-inline-actions.md#build-a-non-flow-host). The host must
parse and validate binding sources before it creates an Action declaration.

## Errors And Limits

Generic failures use `Jido.Expr.Error`. Flow converts expression failures to
its normal structured errors. Runtime errors include `operator`, `reason`,
`expression_path`, and `retry: false`. Reference failures retain the reference
`path` and add the expression location. Error metadata does not include
operand values or unrelated context.

Each complete operation tree, including conditions, has limits of 64 levels,
10,000 visited values, 1,048,576 cumulative binary bytes, and 4,096 bits per
integer magnitude. These limits apply at construction and evaluation.
Evaluation also counts resolved data, comparison work, and generated values.
A Boolean expression tree must fit within the remaining node limit even when
evaluation skips an operand.

Surrounding plain Flow data is outside the operation budget. Flow uses the
fixed limits; a separate host can set the `Jido.Expr` limit options. Stored
documents also have [Codec limits](flow-storage.md#validation-and-limits).

## Elixir Conformance

Supported syntax follows native Elixir for the supported data set. For
example, `1 in [1.0]` is false, and `true and 123` returns `123`. Ordering and
`min` or `max` accept mixed portable values and use term order.

The default test suite includes `test/jido_expr/elixir_conformance_test.exs`.
It lists every accepted spelling and compares trusted fixtures with native
Elixir by strict result comparison. Native evaluation is used only in tests.
