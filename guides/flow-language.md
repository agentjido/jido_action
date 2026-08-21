# Jido Flow Language

The Jido Flow language describes a static graph of action calls. It is a
declarative language. It is not general Elixir control flow.

Use the language to define:

- which actions run
- the data that each action receives
- dependencies between actions
- the value that the Flow returns
- optional authoring metadata

The examples in this guide use the module DSL. The parser accepts the same
language subset. The builder provides functions for the same concepts.

## A Complete Flow

This Flow loads an order. It then prepares pricing and inventory work. The last
step uses both results.

```elixir
defmodule MyApp.Flows.PrepareOrder do
  use Jido.Flow,
    name: "prepare_order",
    description: "Prices an order and reserves its stock",
    schema: Zoi.object(%{order_id: Zoi.string()}),
    output_schema:
      Zoi.object(%{
        order_id: Zoi.string(),
        total: Zoi.number(),
        reservation_id: Zoi.string()
      })

  flow do
    order =
      step(:load_order, MyApp.Actions.LoadOrder,
        with: %{order_id: input(:order_id)},
        label: "Load the order"
      )

    group do
      branch :pricing do
        priced =
          step(:price_order, MyApp.Actions.PriceOrder,
            with: %{
              order: order,
              tenant_id: context(:tenant_id)
            }
          )
      end

      branch :inventory do
        reserved =
          step(:reserve_stock, MyApp.Actions.ReserveStock,
            with: %{order: order}
          )
      end
    end

    prepared =
      step(:prepare_result, MyApp.Actions.PrepareResult,
        with: %{
          order_id: select(order, :id),
          total: select(priced, :total),
          reservation_id: select(reserved, :id)
        }
      )

    return(prepared)
  end
end
```

The source order makes each reference valid. The data references create these
dependencies:

```text
load_order -> price_order -----\
          \                     -> prepare_result
           -> reserve_stock ---/
```

## The Module Header

`use Jido.Flow` defines the Flow metadata and its input and output contracts.

```elixir
use Jido.Flow,
  name: "prepare_order",
  description: "Prices an order and reserves its stock",
  schema: Zoi.object(%{order_id: Zoi.string()}),
  output_schema: Zoi.object(%{total: Zoi.number()})
```

The options are:

| Option | Required | Purpose |
| --- | --- | --- |
| `name` | Yes | Sets the stable Flow name. |
| `description` | No | Explains the Flow purpose. |
| `schema` | No | Validates and normalizes the Flow input. |
| `output_schema` | No | Validates and normalizes the declared return value. |

Schemas must be static and map-shaped. The Flow module validates its
configuration and graph when it compiles.

## `flow do`: Declare The Graph

The `flow do` block contains Flow statements:

```elixir
flow do
  loaded = step(:load, MyApp.Actions.Load, with: %{id: input(:id)})
  saved = step(:save, MyApp.Actions.Save, with: loaded)
  return(saved)
end
```

The language supports these statements:

- `step`
- a binding assignment whose right side is `step`
- `group` with named `branch` blocks
- `return`

The block does not run while the module compiles. The compiler converts each
statement into a canonical `%Jido.Flow{}` artifact.

## `step`: Call An Action

A step adds one named action call to the graph.

```elixir
step(:load_order, MyApp.Actions.LoadOrder,
  with: %{order_id: input(:order_id)}
)
```

The arguments are:

1. A step name
2. An action module
3. An input expression

Step names can be atoms or strings. Canonical Flow artifacts store them as
strings. Each name must be unique.

### Direct Input Form

Pass the input expression as the third argument when the step has no options:

```elixir
step(:load_order, MyApp.Actions.LoadOrder, %{
  order_id: input(:order_id)
})
```

### Keyword Option Form

Use `with:` when the step also has dependencies or annotations:

```elixir
step(:audit_order, MyApp.Actions.AuditOrder,
  with: %{event: "order_prepared"},
  after: :prepare_order,
  label: "Audit the result",
  tags: [:audit, "orders"],
  note: "This annotation is not semantic"
)
```

The keyword form requires `with:`. The option order does not matter.

### Bind A Step Result

Assign a step to a simple variable to create a source handle:

```elixir
loaded =
  step(:load_order, MyApp.Actions.LoadOrder,
    with: %{order_id: input(:order_id)}
  )

saved =
  step(:save_order, MyApp.Actions.SaveOrder,
    with: %{order: loaded}
  )
```

`loaded` is not the action result at compile time. It is a handle that becomes
a reference to the `load_order` result.

A binding can also supply the step name:

```elixir
loaded =
  step(MyApp.Actions.LoadOrder,
    with: %{order_id: input(:order_id)}
  )
```

This form creates a step named `"loaded"`.

Bindings must be unique simple variables. A binding cannot refer to itself.
The reserved bindings are `_`, `flow`, `step`, `return`, `input`,
`context`, `value`, `result`, `select`, `group`, and `branch`.

## Flow Expressions

A step input and the Flow return are expression trees. Maps and lists give the
tree its shape. Reference primitives provide values at runtime.

### `input(path)`

Read a value from the validated Flow input:

```elixir
input(:order_id)
input([:customer, :email])
input([:items, 0, :sku])
```

A path can contain atoms, strings, and integer list indexes. Only non-negative
indexes select list items. A single segment is equivalent to a one-item path.

### `context(path)`

Read a value from the runtime context:

```elixir
context(:tenant_id)
context([:actor, :id])
```

Context data is separate from validated Flow input. Use it for execution data
such as an actor, tenant, trace identifier, or request metadata.

### `value(literal)`

Create one literal expression:

```elixir
value(2)
value(:strict)
value(%{currency: "USD", precision: 2})
```

Direct scalar literals also become value expressions:

```elixir
with: %{
  amount: 2,
  mode: :strict,
  enabled: true,
  note: nil
}
```

Use `value/1` when a complete map or list must remain one literal value.

### `result(step, path \\ [])`

Read the result of a prior named step:

```elixir
result(:load_order)
result(:load_order, :id)
result(:load_order, [:customer, :email])
```

A result reference creates a dependency on that step.

### Binding Handles

A bound step handle is shorthand for its whole result:

```elixir
loaded = step(:load_order, MyApp.Actions.LoadOrder, with: %{id: input(:id)})

step(:save_order, MyApp.Actions.SaveOrder,
  with: loaded
)
```

Use the handle only after its step declaration. Forward references are not
valid.

### `select(source, path)`

Project a nested value from an input, context, result, or binding source:

```elixir
select(input(:payload), [:items, 0, :sku])
select(context(:actor), :id)
select(result(:load_order), [:customer, :email])
select(loaded, :id)
```

Nested `select/2` calls append paths:

```elixir
select(select(loaded, :customer), :email)
```

This expression is equivalent to:

```elixir
select(loaded, [:customer, :email])
```

`select/2` does not accept a literal, map, or list as its source. Paths that
do not exist resolve to `nil`.

### Shape Maps And Lists

Compose references and values inside maps and lists:

```elixir
step(:create_report, MyApp.Actions.CreateReport,
  with: %{
    account_id: input(:account_id),
    actor_id: context([:actor, :id]),
    totals: [
      select(current, :total),
      select(previous, :total)
    ],
    options: %{
      format: "summary",
      include_tax: true
    }
  }
)
```

Map keys must be literals. Lists must be normal lists, not keyword lists.
Arbitrary functions cannot compute expression values.

## Dependencies

Flow has data dependencies and order-only dependencies.

### Inferred Data Dependencies

A step depends on each prior result that appears anywhere in its input:

```elixir
loaded = step(:load, MyApp.Actions.Load, with: %{id: input(:id)})

saved =
  step(:save, MyApp.Actions.Save,
    with: %{
      record: loaded,
      source_id: select(loaded, :id)
    }
  )
```

The `save` step depends on `load`. The dependency is the same when the
reference is nested inside maps or lists.

### `after:`: Order Without Data

Use `after:` when a step needs order but does not consume the earlier result:

```elixir
loaded = step(:load, MyApp.Actions.Load, with: %{id: input(:id)})

step(:audit, MyApp.Actions.Audit,
  with: %{event: "loaded"},
  after: loaded
)
```

The target can be a prior step name, a prior binding handle, or a list of
targets:

```elixir
after: [:load, priced, reserved]
```

`after:` does not accept `result/1` or `select/2`. It adds only graph
edges. It does not add data to the action input.

All result references, binding handles, and `after:` targets must point
backward in the source. This rule makes dependency cycles impossible in the
language.

## `return`: Declare The Flow Result

Every Flow requires one return declaration:

```elixir
return(result(:prepare_order))
```

A binding handle is the shortest form:

```elixir
prepared = step(:prepare_order, MyApp.Actions.PrepareOrder, with: %{})
return(prepared)
```

The return can have a map or list shape:

```elixir
return(%{
  order_id: select(prepared, :order_id),
  total: select(priced, :total),
  original_id: input(:order_id),
  trace_id: context(:trace_id),
  status: "ready"
})
```

The return expression must contain at least one step result. It can also
contain input, context, and literal values. Put `return` last so the source
matches the data flow.

## `group` And `branch`: Show Static Branches

Use a group to show independent authoring branches:

```elixir
group do
  branch :pricing do
    priced =
      step(:price_order, MyApp.Actions.PriceOrder,
        with: %{order: order}
      )
  end

  branch :inventory do
    reserved =
      step(:reserve_stock, MyApp.Actions.ReserveStock,
        with: %{order: order}
      )
  end
end
```

A group has these rules:

- A group contains only named branches.
- Branch names are unique non-nil atoms.
- A branch contains only steps.
- A branch cannot contain `return` or another group.
- A branch can use values declared before the group.
- A binding declared in a branch is available after the group.
- One branch cannot use a binding from a sibling branch.

Groups do not add dependencies. They do not define conditions. They do not
guarantee parallel execution. Branch labels are provenance only. The result
references and `after:` options define the graph.

When `Jido.Exec` runs the Flow with `async: true`, independent eligible
steps can run concurrently.

## Step Annotations

Annotations make authored source easier to inspect:

```elixir
step(:price_order, MyApp.Actions.PriceOrder,
  with: %{order: order},
  label: "Price the order",
  tags: [:commerce, "pricing"],
  note: "Uses the current price book"
)
```

The supported annotations are:

| Annotation | Value |
| --- | --- |
| `label` | A literal string |
| `tags` | A literal list of strings or atoms |
| `note` | A literal string |

Annotations become node provenance. They do not change Flow semantics,
dependencies, execution, or semantic identity.

## The Language Is Deliberately Restricted

The Flow block does not accept arbitrary Elixir. These forms are not language
features:

- `if`, `case`, `cond`, loops, and comprehensions
- function calls that compute step input
- pipes and remote calls
- dot projection such as `loaded.id`
- dynamic action modules or step names
- forward references
- nested groups
- a `parallel` statement
- retry, timeout, compensation, or exception-handling statements

Put computation and side effects inside actions. Use Flow expressions only to
route data and declare dependencies.

The restricted language keeps the graph static. Jido can validate it, inspect
it, create a stable identity, store it, and compile it without running authored
code.

## Primitive Reference

| Primitive | Purpose |
| --- | --- |
| `flow do ... end` | Defines the Flow statement block. |
| `step(name, action, input)` | Adds an action call with direct input. |
| `step(name, action, with: input, ...)` | Adds an action call with options. |
| `handle = step(...)` | Binds a source handle to a step result. |
| `input(path)` | Reads validated Flow input. |
| `context(path)` | Reads runtime context. |
| `value(literal)` | Defines one literal value. |
| `result(step, path)` | Reads a prior named step result. |
| `select(source, path)` | Projects a nested value from a reference source. |
| maps and lists | Build an input or return shape. |
| `after: target` | Adds an order-only dependency. |
| `group` and `branch` | Record static authoring branches. |
| `return(expression)` | Declares the Flow result. |

For runtime options, concurrency, failures, and tracing, see
[Executing Jido Flows](flow-execution.html). For the full execution model, see
[How Jido Flow Works](jido-flow.html).
For module, builder, parser, and stored-map choices, see
[Flow Authoring Languages](flow-authoring-languages.html).
