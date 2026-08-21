# Flows

A Flow is a canonical `%Jido.Flow{}` data type. It describes a named graph of
Action calls and one declared return expression. It is data first: authoring,
inspection, storage, and execution can use the same artifact.

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

The exact node and expression structs are implementation details of the
canonical artifact. Use public builders and authoring surfaces to create them.

## What A Flow Contains

- **Nodes**: named calls to Action modules or nested Flow modules.
- **Dependencies**: predecessor names inferred from references and explicit
  ordering. A node can run when all of its dependencies have completed.
- **Choice**: one node with ordered options and a required fallback. The first
  matching condition selects one target Action.
- **Return expression**: the value assembled from node results, input,
  context, literals, and projections. A Flow has one declared return.
- **Provenance**: non-semantic authoring information. Provenance helps explain
  where a Flow came from but does not change semantic identity.

Nodes use references to map data. Common references read Flow input, runtime
context, literal values, or earlier node results. The Flow language guides
describe these expressions in detail.

## Actions And Flows

Flow nodes call normal `Jido.Action` modules. The Action remains the leaf unit
of work. A Flow adds graph structure around those calls. A Flow module exposes
the Action-compatible validation callbacks and can be passed to
`Jido.Exec.run/4` like an Action.

Action extras are a direct Action or Instruction delivery channel. Flow
execution uses only the node output or error reason, so node extras do not
become Flow data.

## One Data Type, Several Authoring Surfaces

The following authoring surfaces lower into the same canonical `%Jido.Flow{}`
artifact:

- `use Jido.Flow` and its Elixir DSL,
- Flow Script text, and
- `Jido.Flow.Builder` for runtime construction.

This separation lets you author a Flow in one surface, inspect it with
`Jido.Flow.explain/1`, store it as a map, and execute it through
`Jido.Exec`.

## Semantic Identity And Maps

Use the public inspection functions to work with a Flow as data:

```elixir
{:ok, dependencies} = Jido.Flow.dependencies(flow)
{:ok, explanation} = Jido.Flow.explain(flow)
{:ok, identity} = Jido.Flow.semantic_identity(flow)

semantic_map = Jido.Flow.to_map(flow)

actions = %{"double" => MyApp.Actions.Double}
stored_map = Jido.Flow.to_map(flow, format: :stored, actions: actions)

{:ok, restored} =
  Jido.Flow.from_map(stored_map,
    actions: actions,
    schema: flow.schema,
    output_schema: flow.output_schema
  )
```

The semantic map uses deterministic dependency order and excludes provenance.
The stored map replaces Action modules with registry identifiers. Restoring it
requires the same registry and the Flow schemas. Semantic identity represents
the meaning of the Flow, not the authoring order or source location.

## Continue With The Flow Guides

The following guides cover authoring and execution in more detail:

- [Build Your First Flow](build-your-first-flow.livemd) introduces a complete
  Flow.
- [Flow Language](flow-language.livemd) breaks down the language primitives.
- [Nested Flows](nested-flows.livemd) explains Flow nodes that call another
  Flow.
- [Flow Execution](flow-execution.livemd) explains run-to-completion and
  step-wise execution.
