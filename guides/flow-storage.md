# Store And Restore Flows As JSON

The Jido Flow DSL is a compile-time Elixir authoring surface. It does not have
a second text parser. Use the versioned stored-map format when you must save a
Flow in a database, send it to another system, or accept a Flow from an AI
system.

The stored map is canonical Flow data. It keeps all execution details that are
needed to restore the same Flow. It does not keep the original Elixir source or
its layout.

## Create A Stored Map

Action modules and Zoi schemas are runtime terms. A stored map uses stable
string identifiers for these terms. The host supplies the identifiers through
a contract bundle.

```elixir
flow = MyApp.Flows.ProcessOrder.flow()

contracts = %{
  bundle: "my_app/process_order/v1",
  input_schema: "my_app/process_order/input/v1",
  output_schema: "my_app/process_order/output/v1",
  action_registry: "my_app/process_order/actions/v1"
}

bundle =
  Jido.Flow.ContractBundle.new!(
    id: contracts.bundle,
    schemas: %{
      contracts.input_schema => flow.schema,
      contracts.output_schema => flow.output_schema,
      "my_app/payment_state/v1" => MyApp.PaymentState
    },
    action_registries: %{
      contracts.action_registry => %{
        "my_app/load_order/v1" => MyApp.Actions.LoadOrder,
        "my_app/process_payment/v1" => MyApp.Actions.ProcessPayment
      }
    }
  )

contract_bundles = %{bundle.id => bundle}

stored =
  Jido.Flow.to_map(flow,
    format: :stored,
    contracts: contracts,
    contract_bundles: contract_bundles,
    state_schema_ids: %{"payment" => "my_app/payment_state/v1"},
    provenance: true
  )
```

The selected Action registry must contain exactly one identifier for each
Action module in the Flow. `state_schema_ids` maps each internal Iterate node
name to its stable State schema identifier.

Use `provenance: true` when metadata and source annotations must survive the
round trip. Provenance does not change Flow execution or semantic identity.

## Encode And Save JSON

Use the JSON library that your application already owns:

```elixir
json = JSON.encode!(stored)
# Save json in the database.
```

Set transport and database size limits before JSON decoding. The stored-map
reader applies structural limits after decoding, but it does not limit the raw
JSON input.

## Restore The Flow

Decode the JSON and use the same host allow-list:

```elixir
decoded = JSON.decode!(json)

{:ok, restored} =
  Jido.Flow.from_map(decoded, contract_bundles: contract_bundles)

Jido.Flow.to_map(restored, provenance: true) ==
  Jido.Flow.to_map(flow, provenance: true)
```

The restored Flow can be inspected or executed like a compiled module Flow:

```elixir
{:ok, result} = Jido.Exec.run(restored, input, context)
```

## Generate Flows With AI

Ask an AI system to produce the stored JSON schema or an equivalent Elixir
map. Do not ask it to produce DSL source that the application then parses.
Validate the decoded map with `Jido.Flow.from_map/2`. Only allow contract and
Action identifiers that the host registered.

This gives the application one authoring language and one data transport:

- Developers write the compile-time Spark DSL.
- Tools and AI systems create stored maps or JSON.
- `Jido.Flow.from_map/2` restores the canonical Flow.
- `Jido.Exec` executes the canonical Flow.

## Storage Guarantees

The stored format keeps node names, node definitions, expressions,
dependencies, output shape, contract identifiers, and optional provenance. A
stored round trip keeps the Flow meaning. It does not promise source-code
round-trip formatting.

Use `Jido.Flow.semantic_identity/1` to compare Flow meaning before and after a
round trip. See [Inspecting And Storing Flows](flow-inspection.md) for the
inspection API and [Security](security.md) for trust boundaries and limits.
