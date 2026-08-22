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

The exact node and expression structs are implementation details of the
canonical artifact. Use public builders and authoring surfaces to create them.

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

## One DSL And One Data Type

Developers use one compile-time Spark DSL. Applications can use
`Jido.Flow.Builder` when the graph structure comes from runtime data. Both
produce the same canonical `%Jido.Flow{}` artifact:

- `use Jido.Flow` and its compile-time Spark DSL;
- `Jido.Flow.Builder` for runtime construction; and
- versioned stored maps or JSON for transport and persistence.

There is no stored text parser. Tools and AI systems can produce a stored map
or JSON value. `Jido.Flow.from_map/2` validates and restores it.

## Semantic Identity And Maps

Use the public inspection functions to work with a Flow as data:

```elixir
{:ok, dependencies} = Jido.Flow.dependencies(flow)
{:ok, explanation} = Jido.Flow.explain(flow)
{:ok, identity} = Jido.Flow.semantic_identity(flow)

semantic_map = Jido.Flow.to_map(flow)

contracts = %{
  bundle: "my_app/double/v1",
  input_schema: "my_app/double/input/v1",
  output_schema: "my_app/double/output/v1",
  action_registry: "my_app/double/actions/v1"
}

bundle =
  Jido.Flow.ContractBundle.new!(
    id: contracts.bundle,
    schemas: %{
      contracts.input_schema => flow.schema,
      contracts.output_schema => flow.output_schema
    },
    action_registries: %{
      contracts.action_registry => %{
        "my_app/double-action/v1" => MyApp.Actions.Double
      }
    }
  )

contract_bundles = %{bundle.id => bundle}

{:ok, stored_map} =
  Jido.Flow.to_stored_map(flow,
    contracts: contracts,
    contract_bundles: contract_bundles
  )

{:ok, restored} =
  Jido.Flow.from_map(stored_map, contract_bundles: contract_bundles)

{:ok, restored} = Jido.Flow.validate_executable(restored)
```

The semantic map uses deterministic dependency order and excludes provenance.
The stored version 1 map contains stable contract and Action identifiers. Zoi
schemas and Action modules stay in the host bundle. Semantic identity
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
