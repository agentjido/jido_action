# Stored Flow JSON

A stored Flow is one JSON object. Use
`Jido.Flow.Codec.encode/2` and `Jido.Flow.Codec.decode/2`. The same Codec source
file owns both directions.

The Codec converts between a canonical `%Jido.Flow{}` and a JSON-compatible
document map. A JSON library converts this map to or from bytes.

## Trusted Registry

The host application owns one `Jido.Flow.Registry`:

```elixir
registry =
  Jido.Flow.Registry.new!(%{
    "actions/charge" => {:action, MyApp.ChargeCard},
    "flows/refund" => {:flow, MyApp.RefundFlow},
    "actions/charge-old" => {:alias, "actions/charge"},
    "atoms/amount" => {:atom, :amount},
    "schemas/order" => {:schema, MyApp.OrderSchema.schema()},
    "schemas/result" => {:schema, MyApp.ResultSchema.schema()}
  })
```

An Action, Flow, schema, or user-data atom must have a typed Registry entry.
Read aliases can rotate stored identifiers. The encoder always uses the
canonical typed identifier.

A Flow module uses a `:flow` entry. It does not use an `:action` entry, even
though the Flow is Action-compatible.

## Encode and decode

```elixir
{:ok, document} = Jido.Flow.Codec.encode(flow, registry)
json = JSON.encode!(document)

decoded_document = JSON.decode!(json)
{:ok, restored} = Jido.Flow.Codec.decode(decoded_document, registry)

restored == flow
```

The root record has this shape:

```elixir
%{
  "type" => "jido.flow",
  "version" => 1,
  "name" => "process_order",
  "description" => nil,
  "schema" => "schemas/order",
  "output_schema" => "schemas/result",
  "components" => [
    %{
      "kind" => "step",
      "name" => "charge",
      "action" => "actions/charge",
      "params" => %{"$type" => "map", "entries" => []},
      "after" => [],
      "meta" => %{"$type" => "map", "entries" => []}
    }
  ],
  "output" => %{
    "$ref" => %{
      "source" => "result",
      "component" => "charge",
      "path" => []
    }
  }
}
```

Every component has an explicit `kind`. Maps use tagged entry lists so atom,
string, and integer keys remain distinct after a JSON byte round trip.
References and conditions also use explicit tagged records.

## Trust and validation

The decoder rejects unknown fields, component kinds, versions, identifiers,
and wrong Registry kinds. It does not create atoms, derive modules from
strings, or execute the Flow.

The Codec checks collection width and nesting depth before it continues a
recursive decode. Stored data must also pass the portable data grammar.
Functions, PIDs, tuples, and arbitrary structs are not portable values.

Use tuple results for a correction loop:

```elixir
case Jido.Flow.Codec.decode(candidate, registry) do
  {:ok, flow} -> Jido.Flow.validate_executable(flow)
  {:error, error} -> {:error, Jido.Action.Error.to_map(error)}
end
```

This is the initial stored format. The Codec does not infer old record shapes.
