# Expressions In Flows And Host DSLs

`Jido.Expr` adds small, portable calculations to `jido_action` v3. This guide
describes the unreleased expression API. Run the examples in a checkout that
contains this change; `3.0.0-beta.5` does not contain it.

Use an expression for a short calculation or an obvious condition. Use an
inline Step or a named Action when the operation needs an explanation,
validation hooks, application calls, or side effects.

## Calculate At The Point Of Use

Flow captures its data fields before Elixir evaluates them. No import or
`expr(...)` wrapper is required in those fields. The wrapper is optional.
Normal Elixir inside an inline Step body is unchanged.

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
inline Step binding sources, and Flow output. Each field keeps its existing
reference scope and result-shape rules. A normal Flow output is still a map.
Map, Reduce, and Iterate still use Action targets, not inline bodies.

## Complete Operation List

| Syntax | Runtime operator | Rules |
| --- | --- | --- |
| `==`, `!=` | `:eq`, `:neq` | Elixir equality: `1 == 1.0`; atoms and strings differ. |
| `<`, `<=`, `>`, `>=` | `:lt`, `:lte`, `:gt`, `:gte` | Two numbers or two binaries. |
| `in` | `:in` | Right operand is a proper list; membership uses `==`. |
| `and`, `or`, `not` | `:all`, `:any`, `:not` | Strict Boolean operands; `and` and `or` short-circuit. |
| `+`, binary `-`, `*`, `/` | `:add`, `:subtract`, `:multiply`, `:divide` | Numbers only; `/` returns a float. |
| Unary `-` | `:negate` | A number. |
| `div`, `rem` | `:div`, `:rem` | Integers; division truncates toward zero; remainder has the dividend's sign. |
| `min`, `max`, `abs` | `:min`, `:max`, `:abs` | Numbers only. |
| `<>` | `:concat` | Binaries only; no implicit conversion. |

Parentheses use normal Elixir precedence. `all` and `any` accept a non-empty
list. The existing `eq`, `neq`, `lt`, `lte`, `gt`, and `gte` aliases remain.
Portable literals, nested maps/lists, and reference helpers remain valid.

There is no `&&`, `||`, `!`, `===`, `!==`, power, rounding, interpolation,
range, conditional statement, assignment, pipe, function call, or custom
guard system. The fixed numeric helpers above are the only function-shaped
operations. Expressions are not `Jido.Executable` targets.

## Boolean Conditions And Missing Values

`condition: input(:enabled)` and `while not state(:done)` are valid. Their
evaluated values must be Boolean. A present `nil`, number, or string fails.
Use a Boolean schema when the input contract requires a Boolean field.

`false and input(:missing)` skips its second operand. `true or 1 / 0 > 0`
also succeeds. This does not make producer Steps lazy: every result reference
remains a static dependency, including references in skipped operands.

A missing reference is an error. A present `nil` is a value: `input(:value)
== nil` tests that value, but does not catch a missing key. Exact map keys
take priority; an atom path can fall back to its string spelling. A string
path does not create or select an atom key.

## Builder And Direct Construction

Use `Jido.Expr.new!/2` for runtime operator data. Its non-raising `new/2`
checks the operator and arity. Flow constructors then validate the complete
expression and its reference scopes.

The standalone `expr/1` macro uses the same operation syntax. Insert a
prebuilt reference or value with `^variable`. This is a trusted source-code
feature, not syntax accepted from stored documents or inside Flow fields.
Calls inside a pin are rejected; compute a value before the macro if needed.

```elixir
import Jido.Expr, only: [expr: 1]
alias Jido.Flow.{Builder, Ref}

quantity = Ref.input(:quantity)
price = Ref.input(:price)
total = expr(^quantity * ^price)
true = total == Jido.Expr.new!(:multiply, [quantity, price])

{:ok, built} =
  Builder.new(name: "expression_builder")
  |> Builder.step(
    "normalize",
    ExprGuide.Invoice.step_action("normalize"),
    %{name: Ref.input(:name)}
  )
  |> Builder.output(%{total: total})
  |> Builder.build()

{:ok, %{total: 6}} = Jido.Exec.run(built, %{name: "Ada", quantity: 2, price: 3})
```

`Jido.Flow.Ref` and `Jido.Flow.Condition` constructors remain supported.
Conditions can also supply Boolean parameter or output values. Equivalent
condition forms normalize to the same Flow model.

Old Condition-only trees keep their `Jido.Flow.Condition` shape. A condition
with a calculated operand returns one `Jido.Expr` tree. This includes a
calculation inside an `all`, `any`, or `not` group. The complete tree shares
one runtime budget in Choice, Iterate, and data fields.

## Stored JSON

```elixir
{:ok, document, registry} = Jido.Flow.Codec.encode(built)
2 = document["version"]
json = JSON.encode!(document)
{:ok, restored} = Jido.Flow.Codec.decode(JSON.decode!(json), registry)
true = restored == built
{:ok, %{total: 6}} = Jido.Exec.run(restored, %{name: "Ada", quantity: 2, price: 3})
```

An operation has this tagged shape. Its operands use the normal Codec
expression encoding, including Registry-backed reference path atoms:

```json
{"$expr": {"operator": "multiply", "operands": [2, 3]}}
```

The Codec emits version 2 only when a document contains expression nodes.
Existing documents keep version 1 and their existing meaning. This reader
accepts versions 1 and 2, but rejects expression tags in version 1. Older
readers reject version 2. Deploy the new reader before sending new documents.
Literal maps remain tagged maps; a literal key named `$expr` is not code.
Use an application-owned Registry with stable IDs for durable storage.
No operator name or input document can create an atom.

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
validation must not run application work. This PR does not integrate any
other Jido package or add a custom operator registry.

## Errors And Limits

Generic failures use `Jido.Expr.Error`. Flow converts expression failures to
its normal structured errors. Runtime errors include `operator`, `reason`,
`expression_path`, and `retry: false`. Reference failures retain the reference
`path` and add the expression location. Error metadata does not include
operand values or unrelated context.

Each expression evaluation has defaults of 64 levels, 10,000 visited values,
1,048,576 cumulative binary bytes, and 4,096 bits per integer magnitude.
Counts include resolved data, comparison work, and generated values. Thus,
the binary limit is a work/output budget, not only a final string limit.
Before short-circuit evaluation, the operand-list shape of each Boolean
group must fit within the remaining node limit. An oversized group can fail
even when its first operand determines the result. Skipped operands are not
resolved or evaluated. Validation checks the complete expression, including
skipped branches.
These expression limits apply to operation subtrees, not to surrounding
plain Flow data. A plain list, map, string, or integer retains its existing
contract in the module DSL, Builder, and direct constructors. Data used as
an operation operand is subject to the expression limits. Existing plain
references and legacy Condition-only trees retain their contracts.
Flow uses the fixed defaults; a separate host can set the documented
`Jido.Expr` limit options. These limits do not replace an Exec timeout or
the host's input-size policy.

Stored documents also retain Codec limits: 100 levels, 10,000 items per
collection, and 100,000 data nodes. Format overhead counts toward these
limits. An expression can therefore reach a stored-document limit before it
reaches the evaluator's limit.
`Codec.encode/1` and `Codec.encode/2` check the completed document against
these storage limits. They return an error if the document is too large or
too deep for the reader.
