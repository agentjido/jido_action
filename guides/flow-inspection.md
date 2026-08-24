# Inspecting Flows

Every authoring surface produces one canonical `%Jido.Flow{}`. Use the public
inspection functions to understand its graph, compare its meaning, and store
it without depending on source form.

## Inspect Dependencies

`Jido.Flow.dependencies/1` returns the direct predecessors for each node.
Result references and explicit `after:` fields create dependencies. Source
order does not create a dependency.

```elixir
flow = MyApp.Flows.Report.flow()
{:ok, dependencies} = Jido.Flow.dependencies(flow)

["load"] = dependencies["format"]
[] = dependencies["load"]
```

## Explain A Flow

`Jido.Flow.explain/1` returns versioned public inspection data. It includes
Flow metadata, canonical nodes, dependencies, graph edges, the output
expression, and semantic identity.

```elixir
{:ok, explanation} = Jido.Flow.explain(flow)

1 = explanation.version
:flow = explanation.kind
["load", "format"] = Enum.map(explanation.nodes, & &1.name)
```

The node list uses dependency order with node-name tie breaks. The data does
not include an execution-engine value.

## Compare Semantic Identity

`Jido.Flow.semantic_identity/1` returns deterministic SHA-256 and UUIDv8 data
for Flow semantics. Author order and provenance do not change this identity.

```elixir
{:ok, identity} = Jido.Flow.semantic_identity(flow)
is_binary(identity.digest)
is_binary(identity.uuid)
```

Use the identity for caches and change detection.

## Semantic And Stored Maps

`Jido.Flow.to_map/2` returns a deterministic semantic map. It keeps trusted
Action modules and schemas as Elixir terms. It omits provenance unless you set
`provenance: true`.

```elixir
semantic = Jido.Flow.to_map(flow)
with_provenance = Jido.Flow.to_map(flow, provenance: true)
```

For database or JSON storage, create one flat host Registry:

```elixir
registry =
  Jido.Flow.Registry.new!(%{
    "actions/load/v1" => {:action, MyApp.Actions.Load},
    "actions/format/v1" => {:action, MyApp.Actions.Format},
    "schemas/report-input/v1" => {:schema, flow.schema},
    "schemas/report-output/v1" => {:schema, flow.output_schema}
  })

{:ok, stored} = Jido.Flow.to_stored_map(flow, registry, provenance: true)
{:ok, restored} = Jido.Flow.from_stored_map(stored, registry)

Jido.Flow.to_map(restored) == Jido.Flow.to_map(flow)
```

The Registry must have exactly one identifier for every Action, schema, and
data atom that the Flow uses. Data atoms include literals, map keys, and
reference path segments. Missing or ambiguous identifiers are errors.

## Validate A Flow

`Jido.Flow.validate/1` checks canonical Flow structure, schemas, expressions,
references, dependencies, and cycles. It does not load or check Action targets.

`Jido.Flow.validate_executable/1` also checks every Action or nested-Flow target
contract. It does not run Action work.

`Jido.Flow.to_stored_map/3` validates canonical data, identifier resolution,
and JSON-safe encoding. See [Stored Flow JSON](flow-storage.md).

Use `Jido.Exec.run/4` to execute a Flow. Use the step-wise functions when an
application must inspect ready nodes and node results during execution.
