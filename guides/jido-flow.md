# How Jido Flow Works

A Flow is a named graph of action calls with one declared return expression.
Use a Flow when several actions must form one reusable, inspectable data
artifact.

A Flow contains structure, not runtime policy. Retry, timeout, fallback,
persistence, and durable execution stay outside the artifact.

## The Canonical Artifact

All authoring surfaces produce a `%Jido.Flow{}` with these main fields:

- `name` and `description` identify the Flow.
- `schema` validates runtime Flow input.
- `output_schema` validates the declared return value.
- `nodes` contains named action calls.
- `return` declares the result that the Flow returns.
- `provenance` contains non-semantic authoring metadata.

Each `%Jido.Flow.Node{}` has a name, an action module, an input expression, and
dependencies. Node names are strings in the canonical artifact.

## Define A Flow Module

Assume that `MyApp.Actions.Add` and `MyApp.Actions.Multiply` accept a `value`
and an `amount`, and return `%{value: integer}`.

```elixir
defmodule MyApp.Flows.DoubleAfterIncrement do
  use Jido.Flow,
    name: "double_after_increment",
    description: "Adds one, then doubles the result",
    schema: Zoi.object(%{value: Zoi.integer()}),
    output_schema: Zoi.object(%{value: Zoi.integer()})

  alias MyApp.Actions.{Add, Multiply}

  flow do
    added =
      step(:add_one, Add,
        with: %{value: input(:value), amount: value(1)}
      )

    doubled =
      step(:double, Multiply,
        with: %{value: select(added, :value), amount: value(2)}
      )

    return(doubled)
  end
end
```

The module DSL lowers the `flow` block at compile time. Invalid expressions,
unknown result references, cycles, and invalid action contracts cause a compile
error.

The generated module provides these functions:

- `flow/0` returns the canonical artifact.
- `run/2` delegates to `Jido.Exec`.
- `to_map/1` returns a deterministic map.
- `compile/0` returns an inert Runic workflow for graph inspection.
- `dependencies/0`, `explain/0`, and `semantic_identity/0` inspect the graph.
- Action-compatible metadata and validation functions let a Flow module act as
  a node in another Flow.

## Reference Expressions

Node inputs and Flow returns are data expressions. They are not arbitrary
Elixir code.

- `input(path)` reads runtime Flow input.
- `context(path)` reads runtime context.
- `value(term)` stores a literal value.
- `result(node, path)` reads a named prior result.
- `select(source, path)` reads a nested value from another expression.
- A bound step variable is a source-level reference to that step result.

Paths can contain atoms, strings, or non-negative list indexes:

```elixir
flow do
  quote =
    step(:load_quote, MyApp.Actions.LoadQuote,
      with: %{
        id: input(:quote_id),
        first_item: input([:items, 0]),
        tenant_id: context([:tenant, :id])
      }
    )

  priced =
    step(:price_quote, MyApp.Actions.PriceQuote,
      with: %{quote: quote, currency: value("USD")}
    )

  return(%{
    quote_id: select(quote, :id),
    total: select(priced, [:pricing, :total])
  })
end
```

The return expression can be one result or a map or list that contains several
references. It must include at least one node result.

## Dependency Graph

A result reference creates a dependency. In the first example, `double`
depends on `add_one` because its input reads the `add_one` result.

Use `after:` when a node needs an order dependency but does not need prior
result data:

```elixir
flow do
  loaded = step(:load_quote, MyApp.Actions.LoadQuote, with: %{id: input(:id)})

  audited =
    step(:audit_quote, MyApp.Actions.AuditQuote,
      after: loaded,
      with: %{event: value("quote_loaded")}
    )

  return(audited)
end
```

Flow validation combines explicit `after:` dependencies with dependencies from
result references. It rejects unknown nodes and cycles.

## Static Branch Groups

`group` and `branch` make independent authoring branches clear:

```elixir
flow do
  cart = step(:load_cart, MyApp.Actions.LoadCart, with: %{id: input(:cart_id)})

  group do
    branch :pricing do
      priced = step(:price_cart, MyApp.Actions.PriceCart, with: cart)
    end

    branch :inventory do
      reserved = step(:reserve_inventory, MyApp.Actions.ReserveInventory, with: cart)
    end
  end

  finalized =
    step(:finalize_cart, MyApp.Actions.FinalizeCart,
      with: %{priced: priced, reserved: reserved}
    )

  return(finalized)
end
```

Branch names are provenance only. They do not create runtime edges. References
and `after:` declarations define the graph.

## Execution Sequence

Run a Flow module or artifact through `Jido.Exec`:

```elixir
{:ok, %{value: 8}} =
  Jido.Exec.run(MyApp.Flows.DoubleAfterIncrement, %{value: 3}, %{})

flow = MyApp.Flows.DoubleAfterIncrement.flow()
{:ok, %{value: 8}} = Jido.Exec.run(flow, %{value: 3}, %{})
```

Execution uses this sequence:

1. `Jido.Exec` validates the Flow and its input.
2. The compiler converts canonical nodes and edges to a Runic workflow.
3. Runic starts nodes when their dependencies are satisfied.
4. Each node resolves its input expression and runs its action.
5. The runtime extracts the declared return after the graph settles.
6. `Jido.Exec` validates the Flow output.

Independent branches run serially by default. Enable concurrent scheduling at
the public boundary:

```elixir
{:ok, result} =
  Jido.Exec.run(MyApp.Flows.LoadDashboard, input, context,
    async: true,
    max_concurrency: 4
  )
```

Node actions receive the original Flow context. Node extras are discarded.
When a node fails, dependent nodes do not run. An independent branch can still
run while the workflow settles.

## Inspect A Flow

Use `dependencies/1` or `explain/1` to inspect the canonical graph:

```elixir
flow = MyApp.Flows.DoubleAfterIncrement.flow()

{:ok, %{"add_one" => [], "double" => ["add_one"]}} =
  Jido.Flow.dependencies(flow)

{:ok, explanation} = Jido.Flow.explain(flow)
{:ok, identity} = Jido.Flow.semantic_identity(flow)
```

`semantic_identity/1` returns stable SHA-256 and UUIDv8 identities. Provenance
and the authoring order of independent nodes do not change semantic identity.

`Jido.Flow.compile/1` creates an inert Runic workflow for topology inspection.
It does not run actions or resolve runtime input.

## Store A Flow

The default map is an in-memory semantic map. It contains action module atoms
and schemas:

```elixir
semantic = Jido.Flow.to_map(flow)
{:ok, same_flow} = Jido.Flow.from_map(semantic)
```

Use the stored format for JSON-safe data. Map action modules to stable string
identifiers:

```elixir
actions = %{
  "add" => MyApp.Actions.Add,
  "multiply" => MyApp.Actions.Multiply
}

stored =
  Jido.Flow.to_map(flow,
    format: :stored,
    actions: actions,
    provenance: true
  )

{:ok, loaded} =
  Jido.Flow.from_map(stored,
    actions: actions,
    schema: flow.schema,
    output_schema: flow.output_schema
  )
```

Stored maps do not embed executable modules or schemas. The loader must attach
them from trusted application data.

## Authoring Languages

The module DSL is one Flow authoring language. The runtime builder, trusted
source parser, stored source profile, and stored maps produce the same
canonical artifact. See [Flow Authoring Languages](flow-authoring-languages.md)
for equivalent examples and selection guidance.
