# Flows

A Flow is a canonical `%Jido.Flow{}` data type. It describes a named graph of
Flow elements and one output expression. It is data first: authoring,
inspection, storage, and execution use the same artifact.

```elixir
%Jido.Flow{
  name: "double_value",
  nodes: [...],
  return: ...,
  schema: ...,
  output_schema: ...,
  provenance: ...
}
```

Flow element structs are stable, read-only data types. Their fields let tools
inspect the canonical artifact. Use a supported authoring route to create a
Flow instead of direct struct construction.

## What A Flow Contains

- **Step**: one named call to an Action module or nested Flow module.
- **Map**: one named fan-out over a proper list. Each item calls one target.
- **Reduce**: one named serial left fold over a proper list.
- **Iterate**: one named bounded iteration with an internal State contract. It
  lowers to the canonical `Jido.Flow.Iterator` runtime node.
- **Dependencies**: predecessor names inferred from references and explicit
  ordering. An element can run when all of its dependencies have completed.
- **Choice**: one node with ordered options and a required fallback. The first
  matching condition selects one target.
- **Output expression**: the value assembled from node results, input,
  context, literals, and projections. The last node is the output when an
  explicit `output` declaration is absent.
- **Provenance**: non-semantic authoring information. Provenance helps explain
  where a Flow came from but does not change semantic identity.

Elements use references to map data. Common references read Flow input,
runtime context, literal values, or earlier results. Map and Reduce add
item-local references. Iterate adds State and iteration-local references. The
Flow language guides describe these expressions in detail.

## Actions And Flows

Step, Choice, Map, Reduce, and Iterate targets call normal `Jido.Action` modules
or nested Flow modules. The Action remains the leaf unit of work. A Flow adds
graph and iteration structure around those calls. A Flow module exposes the
Action-compatible validation callbacks and can be passed to `Jido.Exec.run/4`
like an Action.

Action extras are a direct Action or Instruction delivery channel. Flow
execution uses only the node output or error reason, so node extras do not
become Flow data.

## One DSL And One Data Model

Developers use one compile-time Flow module DSL. Applications can use
`Jido.Flow.Builder` when the graph structure comes from runtime data. All three
inputs produce the same canonical `%Jido.Flow{}` artifact:

- `use Jido.Flow` and its compile-time module DSL;
- `Jido.Flow.Builder` for runtime construction; and
- versioned stored maps or JSON for transport and persistence.

There is no stored text parser. Tools and AI systems can produce a stored map
or JSON value. `Jido.Flow.from_stored_map/2` validates and restores it through
a trusted host Registry.

These three inputs use one constructor and one expression model. Element
structs expose the canonical data. `Jido.Flow.to_map/2` returns a semantic
inspection view. Neither one is another source language.

The module DSL calls the final declaration `output`. Builder and the canonical
artifact call the field `return`. The module DSL calls a repeated form
`iterate`; the artifact stores it as `Jido.Flow.Iterator`. These are deliberate
source-to-data boundaries.

## Public And Private Boundaries

`Jido.Flow` is the public artifact and inspection facade. `Jido.Flow.Builder`
is the public runtime construction facade. `Jido.Flow.Registry` controls the
trusted identifiers in stored maps. `Jido.Exec` is the public execution
facade.

Compiler, Map codec, graph analysis, and graph engine adapter modules are
private. They can change without a public API change. Treat the execution value
as opaque and use only `Jido.Exec` functions to read or advance it.

## Semantic Identity And Maps

Use the public inspection functions to work with a Flow as data:

```elixir
{:ok, dependencies} = Jido.Flow.dependencies(flow)
{:ok, explanation} = Jido.Flow.explain(flow)
{:ok, identity} = Jido.Flow.semantic_identity(flow)

semantic_map = Jido.Flow.to_map(flow)

registry =
  Jido.Flow.Registry.new!(%{
    "my_app/double-action/v1" => {:action, MyApp.Actions.Double},
    "my_app/double-input/v1" => {:schema, flow.schema},
    "my_app/double-output/v1" => {:schema, flow.output_schema}
  })

{:ok, stored_map} =
  Jido.Flow.to_stored_map(flow, registry)

{:ok, restored} =
  Jido.Flow.from_stored_map(stored_map, registry)

{:ok, restored} = Jido.Flow.validate_executable(restored)
```

The semantic map uses deterministic dependency order and excludes provenance.
The stored version 1 map contains stable schema and Action identifiers. Zoi
schemas and Action modules stay in the host Registry. Semantic identity
represents the meaning of the resolved Flow, not transport identifiers,
authoring order, or source location.

## Continue With The Flow Guides

The following guides cover authoring and execution in more detail:

- [Build Your First Flow](build-your-first-flow.livemd) introduces a complete
  Flow.
- [Flow Language](flow-language.livemd) breaks down the language primitives.
- [Map and Reduce](flow-collections.livemd) explains ordered collection
  processing.
- [Iterate and State](flow-iterate-state.livemd) explains bounded stateful
  iteration.
- [Stored Flow JSON](flow-storage.md) explains portable canonical storage.
- [Nested Flows](nested-flows.livemd) explains Flow nodes that call another
  Flow.
- [Flow Execution](flow-execution.livemd) explains run-to-completion and
  step-wise execution.
