# Inspecting And Storing Flows

Every authoring surface produces a canonical `%Jido.Flow{}`. Use the public
inspection functions to understand its graph, compare its meaning, and store
it without depending on the source format. This guide complements [Flows as a
data type](flows.md).

## Inspect Dependencies

`Jido.Flow.dependencies/1` returns direct predecessors for each node. The
dependencies come from result references and explicit `after:` options. Group
and branch names do not become runtime nodes or dependencies.

```elixir
flow = MyApp.Flows.Report.flow()

{:ok, dependencies} = Jido.Flow.dependencies(flow)

["load"] = dependencies["format"]
[] = dependencies["load"]
```

The map uses canonical node names. A node can run after all names in its list
complete. See [Flow Dependencies](flow-dependencies.livemd).

## Explain A Flow

`Jido.Flow.explain/1` returns versioned inspection data. It includes the Flow
metadata, canonical nodes, dependencies, graph edges, return expression, and
semantic identity.

```elixir
{:ok, explanation} = Jido.Flow.explain(flow)

1 = explanation.version
:flow = explanation.kind
["load", "format"] = Enum.map(explanation.nodes, & &1.name)
```

The node list is in dependency order with node-name tie breakers. This gives
stable output for inspection tools.

## Compare Semantic Identity

`Jido.Flow.semantic_identity/1` returns deterministic SHA-256 and UUIDv8
identity data for the Flow's semantic meaning. Authoring order and provenance
do not change that meaning.

```elixir
{:ok, identity} = Jido.Flow.semantic_identity(flow)
is_binary(identity.digest)
is_binary(identity.uuid)
```

Use this identity for caches, change detection, and registry uniqueness. A
registry that stores semantic Flows should reject duplicate identities for
different stored records unless they intentionally refer to the same Flow.

## Semantic And Stored Maps

`Jido.Flow.to_map/2` returns a deterministic semantic map by default. It keeps
Action modules and schemas as module data and omits provenance unless requested.

```elixir
semantic = Jido.Flow.to_map(flow)
with_provenance = Jido.Flow.to_map(flow, provenance: true)
```

Use `format: :stored` to produce a portable stored version 1 map. The stored
map contains stable identifiers. Zoi schemas and Action modules stay in a
host-supplied contract bundle:

```elixir
contracts = %{
  bundle: "my_app/report/v1",
  input_schema: "my_app/report/input/v1",
  output_schema: "my_app/report/output/v1",
  action_registry: "my_app/report/actions/v1"
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
        "my_app/load/v1" => MyApp.Actions.Load,
        "my_app/format/v1" => MyApp.Actions.Format
      }
    }
  )

contract_bundles = %{bundle.id => bundle}

stored =
  Jido.Flow.to_map(flow,
    format: :stored,
    contracts: contracts,
    contract_bundles: contract_bundles,
    provenance: true
  )
```

The selected registry must have exactly one identifier for every Action module
used by the Flow. Missing identifiers and multiple identifiers for one module
are errors. This rule keeps stored maps unambiguous.

## Restore A Stored Flow

Stored maps contain the Flow name, node definitions, return expression, stable
contract references, and stable Action identifiers. Restore the map with the
same host allow-list:

```elixir
{:ok, restored} =
  Jido.Flow.from_map(stored, contract_bundles: contract_bundles)

Jido.Flow.to_map(restored) == Jido.Flow.to_map(flow)
```

The stored round trip preserves deterministic Flow data and optional
provenance. It does not preserve Elixir source. The host bundle resolves the
schemas and Action registry without putting runtime terms in JSON. See [Flow
Script](flow-script.md) for the separate stored source profile.

## Provenance

Provenance is non-semantic metadata attached by authoring tools. Include it in
maps with `provenance: true` when a review or inspection tool needs labels,
tags, notes, or source annotations:

```elixir
stored_with_notes =
  Jido.Flow.to_map(flow,
    format: :stored,
    contracts: contracts,
    contract_bundles: contract_bundles,
    provenance: true
  )
```

The default semantic map and identity do not include provenance.

## Compile A Graph For Inspection

`Jido.Flow.compile/1` returns an inert Runic workflow. It validates the Flow and
builds graph-shaped node markers for inspection. It does not have runtime input
or context, and it does not execute Action work.

```elixir
{:ok, workflow} = Jido.Flow.compile(flow)
%Runic.Workflow{} = workflow
```

Use [`Jido.Exec.run/4`](flow-execution.livemd) to execute a Flow. Use
[`Jido.Exec.start/4`](flow-execution.livemd) and the step-wise API when you need
runtime status and node results.
