# Stored Flow JSON

A stored Flow is a versioned JSON object. It contains stable string identifiers
for Actions and schemas. It does not contain Elixir module names or schema
terms.

The host application owns one flat `Jido.Flow.Registry`:

```elixir
registry =
  Jido.Flow.Registry.new!(%{
    "actions/charge-card/v1" => {:action, MyApp.ChargeCard},
    "schemas/order/v1" => {:schema, MyApp.OrderSchema.schema()},
    "schemas/result/v1" => {:schema, MyApp.ResultSchema.schema()},
    "schemas/payment-state/v1" => {:schema, MyApp.PaymentState.schema()}
  })
```

Each identifier maps directly to one typed trusted value. An Action entry is
`{:action, module}`. A schema entry is `{:schema, schema}`. The Registry rejects
invalid identifiers, duplicate semantic values, and more than 10,000 entries.

## Write

Call `Jido.Flow.to_stored_map/3`:

```elixir
{:ok, stored} = Jido.Flow.to_stored_map(flow, registry)
json = Jason.encode!(stored)
```

The optional third argument accepts only `provenance: true`. Provenance is off
by default and does not affect semantic identity.

The root record has these fields:

```elixir
%{
  "type" => "flow",
  "version" => 1,
  "name" => "process_order",
  "description" => nil,
  "input_schema" => "schemas/order/v1",
  "output_schema" => "schemas/result/v1",
  "nodes" => [...],
  "return" => %{...}
}
```

Each node stores its Action identifier in its own `"action"` field. An Iterate
node stores its State schema identifier in `"state"["schema"]`. There is no
second registry record or schema attachment.

## Read

Decode JSON to a map and call `Jido.Flow.from_stored_map/2`:

```elixir
decoded = Jason.decode!(json)
{:ok, restored} = Jido.Flow.from_stored_map(decoded, registry)
```

The reader first checks structural resource limits. It then validates the exact
stored grammar, resolves each identifier through the supplied Registry, and
uses the same canonical constructor as the Spark DSL and Builder.

The reader does not convert stored strings to atoms. It does not derive module
names, load modules, or accept Action modules and schemas from the stored map.
Call `Jido.Flow.validate_executable/1` or `Jido.Exec.run/4` when you must check
that resolved Action modules can execute.

## Resource limits

Stored input has fixed limits:

- Nesting depth: 64.
- Total term slots: 100,000.
- Total binary bytes: 1,048,576.
- One collection width: 10,000.

These checks protect database and AI-produced maps before recursive decoding.

## Round-trip rule

For a valid Registry, this property must hold:

```elixir
{:ok, stored} = Jido.Flow.to_stored_map(flow, registry)
{:ok, restored} = Jido.Flow.from_stored_map(stored, registry)

Jido.Flow.to_map(restored) == Jido.Flow.to_map(flow)
```

The stored identifiers can differ between hosts. The resolved Flow semantics
must not differ.
