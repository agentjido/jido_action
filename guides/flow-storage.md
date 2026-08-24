# Stored Flow JSON

A stored Flow is a versioned JSON object. It contains stable string identifiers
for Actions, schemas, and data atoms. It does not contain Elixir module names,
schema terms, or atom names.

The host application owns one flat `Jido.Flow.Registry`:

```elixir
registry =
  Jido.Flow.Registry.new!(%{
    "actions/charge-card/v1" => {:action, MyApp.ChargeCard},
    "atoms/amount/v1" => {:atom, :amount},
    "atoms/approved/v1" => {:atom, :approved},
    "atoms/order-id/v1" => {:atom, :order_id},
    "schemas/order/v1" => {:schema, MyApp.OrderSchema.schema()},
    "schemas/result/v1" => {:schema, MyApp.ResultSchema.schema()},
    "schemas/payment-state/v1" => {:schema, MyApp.PaymentState.schema()}
  })
```

Each identifier maps directly to one typed trusted value. An Action entry is
`{:action, module}`. A schema entry is `{:schema, schema}`. A data atom entry is
`{:atom, atom}`. The Registry rejects invalid identifiers, untyped entries,
and more than 10,000 entries. Stored writing rejects a missing or ambiguous
identifier for a semantic value.

Add an atom entry for each atom literal, atom map key, and atom reference path
segment in the Flow. Fixed grammar values, such as the `:gte` condition
operator and the `:fail_fast` Map mode, do not need atom entries. The writer
stores a data atom as a tagged Registry identifier:

```elixir
%{"$type" => "atom", "value" => "atoms/approved/v1"}
```

## Write

Call `Jido.Flow.to_stored_map/3`:

```elixir
{:ok, stored} = Jido.Flow.to_stored_map(flow, registry)
json = JSON.encode!(stored)
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
decoded = JSON.decode!(json)
{:ok, restored} = Jido.Flow.from_stored_map(decoded, registry)
```

The reader first checks structural resource limits. It then validates the exact
stored grammar, resolves each identifier through the supplied Registry, and
uses the same canonical constructor as the Flow module DSL and Builder.

The reader does not convert stored strings to atoms. It resolves tagged atom
identifiers only through `{:atom, atom}` entries in the supplied Registry. It
does not derive module names, load modules, or accept Action modules, schemas,
or atoms from the stored map. Call `Jido.Flow.validate_executable/1` or
`Jido.Exec.run/4` when you must check that resolved Action modules can execute.

This tuple-returning read API supports a correction loop for a web UI or an AI
agent:

```elixir
case Jido.Flow.from_stored_map(candidate, registry) do
  {:ok, flow} -> {:ok, flow}
  {:error, error} -> {:error, Jido.Action.Error.to_map(error)}
end
```

The reader reports the first validation error. Error details include a field,
record, or path when that context is available.

## Resource limits

The writer and reader use the same fixed limits. A successful write does not
produce a map that the reader rejects for size or structure. All stored string
values must contain valid UTF-8.

Stored maps have these limits:

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

Each host that reads the same artifact must know its stored identifiers. A host
can map those identifiers to equivalent local schema terms, Action modules, and
atoms. The resolved Flow semantics must not differ.
