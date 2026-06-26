# Jido.Flow Syntax Overview

This document describes the Flow syntax currently supported in this branch.
Flow is IR-first: each authoring surface lowers into the same canonical
`%Jido.Flow{}` artifact before compilation or execution.

The current language is intentionally small. It can model named action steps,
data dependencies, explicit ordering edges, structured input shaping, runtime
context reads, static branch grouping, provenance-only annotations, and a safer
stored-source parser profile. It does not yet model dynamic control flow such
as conditionals, collection mapping, reduction, accumulation, loops, or ReAct
agent loops.

## Authoring Surfaces

The supported authoring surfaces are:

- Compile-time macro DSL through `use Jido.Flow`.
- Runtime text parsing through `Jido.Flow.parse/2`.
- Runtime builder API through `Jido.Flow.Builder`.
- Direct syntax construction through `Jido.Flow.Syntax`.

All surfaces are expected to produce equal canonical maps for equivalent flows.
The text parser and macro DSL share the same source grammar for the currently
supported subset.

## Flow Metadata

Flow metadata lives outside the current source `flow do` block.

For compile-time modules:

```elixir
defmodule MyApp.Flows.PriceAndAudit do
  use Jido.Flow,
    name: "price_and_audit",
    description: "Price a cart and emit an audit payload",
    schema: [],
    output_schema: []

  flow do
    quote =
      step :price_cart, MyApp.Actions.PriceCart,
        with: %{cart_id: input(:cart_id)}

    return quote
  end
end
```

For parsed source:

```elixir
source = """
flow do
  quote =
    step :price_cart, MyApp.Actions.PriceCart,
      with: %{cart_id: input(:cart_id)}

  return quote
end
"""

Jido.Flow.parse(source,
  name: "price_and_audit",
  description: "Price a cart and emit an audit payload"
)
```

The current parser expects a single `flow do ... end` block. Source-level flow
names, schemas, or options inside the `flow` call are not part of the supported
syntax yet.

## Steps

A step names one action invocation.

```elixir
step :add_one, MyApp.Actions.Add, %{value: input(:value), amount: value(1)}
```

The keyword form is preferred when using bindings, explicit edges, or
annotations:

```elixir
added =
  step :add_one, MyApp.Actions.Add,
    with: %{value: input(:value), amount: value(1)}
```

Supported step options are:

- `with:` - required in keyword-form steps; supplies the action params
  expression.
- `after:` - optional explicit dependency target or list of targets.
- `label:` - optional provenance-only string.
- `tags:` - optional provenance-only list of strings or atoms.
- `note:` - optional provenance-only string.

The step name must be a non-nil atom. In trusted source, the action can be a
module alias or module atom. In stored source, actions must resolve through the
explicit action registry described below.

## Binding Handles

A step may be assigned to a local binding handle:

```elixir
cart =
  step :load_cart, MyApp.Actions.LoadCart,
    with: %{cart_id: input(:cart_id)}

quote =
  step :price_cart, MyApp.Actions.PriceCart,
    with: %{cart: cart}

return quote
```

Bindings are source-level aliases for step results. They lower to result refs in
the canonical Flow IR and do not appear in default semantic maps.

Binding rules:

- A binding can only be introduced by assigning a `step`.
- A binding can be used as a root expression or nested inside maps, lists, and
  `shape(...)`.
- A binding must refer to a previously bound step.
- Duplicate bindings are rejected.
- A binding cannot collide with a step name.
- Reserved names such as `flow`, `step`, `return`, `input`, `context`, `value`,
  `result`, `select`, `shape`, `parallel`, and `branch` are rejected.

## Return

Every Flow must declare a return value:

```elixir
return quote
```

The return expression must resolve to a result ref. Supported return shapes
include:

```elixir
return quote
return result(:price_cart)
return result(:price_cart, :total)
return select(quote, :total)
return select(result(:price_cart), [:pricing, :total])
```

Returning input refs, context refs, literal values, arbitrary maps/lists, or
`shape(...)` is not supported in the current return contract.

## Expressions

Expressions are data. They do not evaluate arbitrary Elixir.

### `input(path)`

Reads from Flow input params.

```elixir
input(:cart_id)
input([:items, 0, :sku])
```

### `context(path)`

Reads from the runtime execution context passed to `Jido.Exec.run/3`.

```elixir
context(:trace_id)
select(context(:tenant), :id)
```

Context refs are part of the Flow artifact, but runtime context values are not
captured in canonical maps.

### `value(literal)`

Wraps a literal value explicitly.

```elixir
value(1)
value("audit")
value(%{static: true})
```

Plain literal atoms, strings, numbers, booleans, and `nil` in expression
positions are also treated as values.

### `result(step, path \\ [])`

References a previous step result by step name.

```elixir
result(:price_cart)
result(:price_cart, :total)
result(:price_cart, [:pricing, :total])
```

Result refs must point to steps that have already appeared in the source.

### Maps and Lists

Step inputs can be structured maps and lists containing nested expressions:

```elixir
step :audit_quote, MyApp.Actions.AuditQuote,
  with: %{
    quote_id: select(quote, :id),
    total: select(quote, [:pricing, :total]),
    tags: [input(:tag), "checkout"]
  }
```

Map keys must be literals. List elements may be expressions. Keyword lists are
not supported as expression data.

### `shape(data)`

`shape(...)` is readability sugar for structured data. It does not change the
canonical IR compared with the equivalent raw map or list.

```elixir
step :audit_quote, MyApp.Actions.AuditQuote,
  with:
    shape(%{
      quote_id: select(quote, :id),
      total: select(quote, [:pricing, :total])
    })
```

### `select(source, path)`

Projects a nested path from an existing projection-capable source:

```elixir
select(quote, :total)
select(input(:items), [0, :id])
select(select(quote, :pricing), :total)
select(context(:tenant), :id)
```

`select(...)` sources must resolve to input, context, or result refs. Selecting
from literal values, maps, or lists is rejected. Path segments must be atoms,
strings, or integers.

## Dependency Semantics

Flow does not treat source order as an implicit dependency between unrelated
steps.

Dependencies come from:

- Result refs in step inputs.
- Binding refs in step inputs.
- Explicit `after:` edges.

For example, `audit_quote` depends on `load_quote` because it reads `quote`.
`independent` has no dependency on `load_quote` just because it appears later:

```elixir
quote =
  step :load_quote, MyApp.Actions.LoadQuote,
    with: %{quote_id: input(:quote_id)}

step :independent, MyApp.Actions.AuditEvent,
  with: %{event: "side"}

step :audit_quote, MyApp.Actions.AuditQuote,
  with: %{quote_id: select(quote, :id)}
```

Use `after:` when ordering matters but there is no data dependency:

```elixir
loaded =
  step :load_quote, MyApp.Actions.LoadQuote,
    with: %{quote_id: input(:quote_id)}

step :audit_quote, MyApp.Actions.AuditQuote,
  with: %{event: "quoted"},
  after: loaded
```

`after:` accepts a prior step name, a prior binding handle, or a list of those:

```elixir
after: :load_quote
after: loaded
after: [:load_quote, loaded]
```

Forward references, unknown targets, self-dependencies, and expression targets
such as `select(loaded, :id)` are rejected.

## Static Branch Grouping

`parallel do` groups branches in the source:

```elixir
parallel do
  branch :pricing do
    priced =
      step :price_cart, MyApp.Actions.PriceCart,
        with: %{cart: cart}

    step :audit_price, MyApp.Actions.AuditEvent,
      with: %{event: "priced"},
      after: priced
  end

  branch :inventory do
    reserved =
      step :reserve_inventory, MyApp.Actions.ReserveInventory,
        with: %{cart: cart}
  end
end

step :finalize, MyApp.Actions.Finalize,
  with: %{priced: priced, reserved: reserved}
```

Branch grouping is static and provenance-only in the canonical semantic map.
The lowerer flattens branch steps into ordinary Flow nodes. Branch names are
available only when converting with provenance enabled.

Current branch rules:

- `parallel` must use a `do` block.
- Each entry must be `branch :name do ... end`.
- Branch names must be unique non-nil atoms.
- Branch bodies may contain only steps.
- Branch bodies cannot contain `return`, nested `parallel`, or arbitrary
  operations.
- A branch can reference bindings available before the group.
- Bindings introduced inside branches are available after the group.
- A branch cannot reference bindings introduced by a sibling branch while still
  inside the branch body.

## Annotations and Provenance

Steps support provenance-only annotations:

```elixir
added =
  step :add_one, MyApp.Actions.Add,
    with: %{value: input(:value), amount: value(1)},
    label: "Add one",
    tags: [:math, "example"],
    note: "Visible only in provenance"
```

Annotations do not affect execution, dependencies, return values, or default
canonical maps:

```elixir
Jido.Flow.to_map(flow)
```

They are visible only when provenance is requested:

```elixir
Jido.Flow.to_map(flow, provenance: true)
```

Annotation rules:

- `label` must be a string.
- `note` must be a string.
- `tags` must be a list of strings or atoms.
- Tag atoms normalize to strings during lowering.
- Parser and macro source accept literal annotation values only.

Parser and macro DSL provenance may also include source `line` and `column`
metadata when available.

## Stored Source Profile

`Jido.Flow.parse/2` defaults to the trusted developer profile:

```elixir
Jido.Flow.parse(source, name: "trusted_flow")
Jido.Flow.parse(source, name: "trusted_flow", profile: :trusted)
```

Stored or user-edited source can opt into the stored profile:

```elixir
source = """
flow do
  added =
    step :add_one, "add",
      with: %{value: input(:value), amount: value(1)}

  return added
end
"""

Jido.Flow.parse(source,
  name: "stored_flow",
  profile: :stored,
  actions: %{"add" => MyApp.Actions.Add}
)
```

Stored profile behavior:

- Uses `Code.string_to_quoted/2` with `existing_atoms_only: true`.
- Does not create arbitrary atoms from source text.
- Requires action identifiers to resolve through the `actions:` registry.
- Accepts string or atom registry keys.
- Requires registry values to be module atoms.
- Rejects direct module aliases in action position.

Step names and local binding syntax still lower to the current atom-based IR, so
stored source must use atoms that already exist.

## Builder and Direct Syntax Equivalents

The builder API mirrors the same expression vocabulary:

```elixir
alias Jido.Flow.Builder

builder =
  Builder.new(name: "price_and_audit")
  |> Builder.step(
    :load_quote,
    MyApp.Actions.LoadQuote,
    Builder.shape(%{
      quote_id: Builder.input(:quote_id),
      trace_id: Builder.context(:trace_id)
    }),
    bind: :quote
  )
  |> Builder.step(
    :audit_quote,
    MyApp.Actions.AuditQuote,
    Builder.shape(%{
      quote_id: Builder.select(Builder.binding(:quote), :id)
    })
  )
  |> Builder.return(Builder.binding(:quote))

{:ok, flow} = Builder.build(builder)
```

`Jido.Flow.Syntax` exposes the same lower-level constructors:

- `Syntax.input/1`
- `Syntax.context/1`
- `Syntax.value/1`
- `Syntax.result/2`
- `Syntax.binding/1`
- `Syntax.select/2`
- `Syntax.shape/1`
- `Syntax.step/5`
- `Syntax.branch/3`
- `Syntax.parallel/3`
- `Syntax.return/2`

Use `Builder` for runtime programmatic construction. Use `Syntax` directly when
tests or tooling need to construct the shared syntax layer itself.

## Explicitly Unsupported Today

The current Flow source subset rejects arbitrary Elixir and unsupported control
flow. Not supported today:

- `if`, `case`, `cond`, `choose`, predicates, or conditional branches.
- `each`, map, reduce, accumulate, fold, or collection blocks.
- Loops, retries, timeouts, scheduler policy, checkpoints, memory, approvals,
  or ReAct agent loops.
- Branch-local returns or branch result joining semantics.
- Nested `parallel` groups.
- Arbitrary function calls in expressions.
- Remote calls such as `String.upcase("x")`.
- Captures, comprehensions, imports, requires, module attributes, and nested
  module definitions.
- Property access syntax such as `quote.total`.
- Returning arbitrary shaped data with `return shape(...)`.
- Source-level flow metadata inside `flow ... do`.

These restrictions are deliberate. Flow syntax should only expose concepts that
have a clear canonical IR meaning and parity across the supported authoring
surfaces.

## Quick Reference

Supported source forms:

```elixir
flow do
  step :name, ActionModule, input_expr

  handle =
    step :name, ActionModule,
      with: input_expr,
      after: prior_step_or_binding,
      label: "Human label",
      tags: [:tag, "other"],
      note: "Provenance-only note"

  parallel do
    branch :name do
      step :branch_step, ActionModule, with: input_expr
    end
  end

  return result_or_binding_or_select
end
```

Supported expression helpers:

```elixir
input(path)
context(path)
value(literal)
result(:step)
result(:step, path)
select(source, path)
shape(data)
```

Supported path segment types:

- atom
- string
- integer

Supported path shapes:

```elixir
:field
"field"
0
[:items, 0, :id]
nil # normalizes to the root path
```
