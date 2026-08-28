# Store Flows As JSON

`Jido.Flow.Codec` is the one serialization and deserialization boundary for
canonical Flows. It uses a trusted `Jido.Flow.Registry` to map portable
identifiers to host modules, schemas, and atoms.

## Build A Trusted Registry

```elixir
registry =
  Jido.Flow.Registry.new!(%{
    "actions/create-greeting" => {:action, MyApp.Actions.CreateGreeting},
    "flows/greeting" => {:flow, MyApp.Flows.Greeting},
    "schemas/greeting-input" => {:schema, MyApp.Flows.Greeting.schema()},
    "schemas/greeting-output" => {:schema, MyApp.Flows.Greeting.output_schema()},
    "atoms/name" => {:atom, :name},
    "atoms/owner" => {:atom, :owner},
    "atoms/priority" => {:atom, :priority},
    "actions/old-greeting" => {:alias, "actions/create-greeting"}
  })
```

Each typed entry is the canonical write identifier for one value. An alias is
read-only and must point directly to a typed entry. The Registry rejects
ambiguous write identifiers.

The host application owns the Registry. Stored data never creates atoms,
derives module names, or selects an unregistered schema.

## Generate A Temporary Registry

Use `Jido.Flow.Codec.encode/1` when stable application identifiers are not
required:

```elixir
{:ok, document, registry} = Jido.Flow.Codec.encode(flow)
{:ok, json} = Jason.encode(document)

{:ok, decoded_document} = Jason.decode(json)
{:ok, decoded_flow} = Jido.Flow.Codec.decode(decoded_document, registry)
```

`encode/1` validates the executable Flow. It collects its Action modules,
child Flow modules, schemas, and data atoms. It assigns generated identifiers
and returns the Registry separately.

The generated identifiers are deterministic only for the exact Flow value.
They can change after a Flow, module, or schema change. Use them only for
temporary storage, tests, or transport within one application version. Keep
the Registry available until decoding is complete. Use an application-owned
Registry for durable storage.

## Encode And Decode

```elixir
flow = MyApp.Flows.Greeting.flow()

{:ok, document} = Jido.Flow.Codec.encode(flow, registry)
{:ok, json} = Jason.encode(document)

{:ok, decoded_document} = Jason.decode(json)
{:ok, decoded_flow} = Jido.Flow.Codec.decode(decoded_document, registry)
```

The Codec document is JSON-compatible and versioned. Use the JSON library
that your application already owns.

```elixir
%{
  "type" => "jido.flow",
  "version" => 1,
  "name" => "greeting"
} = Map.take(document, ["type", "version", "name"])
```

The root also contains `description`, `schema`, `output_schema`, `components`,
and `output`.

The exact component and expression fields are owned by Codec. Do not hand-edit
a semantic `Jido.Flow.to_map/1` result into a stored document.

## Validation And Limits

Decode first checks the stored grammar and resource limits. It rejects:

- invalid UTF-8;
- nesting deeper than 100 levels;
- one map or list with more than 10,000 items;
- a document with more than 100,000 data nodes;
- unknown or extra fields;
- unknown Registry identifiers; and
- invalid canonical Flow data.

These limits do not bound HTTP bytes or the JSON parser. Apply transport and
parser limits before `decode/2`.

Decode is inert. It does not run Actions. Call
`Jido.Flow.validate_executable/1` when you want a target-contract check, or
run through `Jido.Exec`.

## Diagnose An Editor Draft

`decode/2` returns the first error. Use `diagnose/2` when a browser editor must
show all independent document and graph errors:

```elixir
case Jido.Flow.Codec.diagnose(editor_document, registry) do
  {:ok, flow} ->
    {:ok, flow}

  {:error, errors} ->
    {:error, Jido.Flow.Error.to_map(errors)}
end
```

The error is one `%Jido.Flow.Error.Invalid{}` Splode group. Its ordered leaf
errors have JSON paths when a path applies. The stable error map contains the
leaf errors under `details.errors`.

Diagnostics collect errors across root fields, components, nested Choice
records, Dynamic records, expressions, conditions, lists, maps, and graph
references. They do not return a partial Flow. Unknown-reference errors
suppress a derived cycle error because that cycle result would be misleading.

Document size, collection size, nesting, root type, and document version
errors are terminal. Diagnostics do not traverse a document after one of
these failures.

`diagnose/2` checks the stored and canonical Flow contract. It does not check
whether resolved Action or child Flow modules are executable. After a valid
decode, call `Jido.Flow.validate_executable/1` when the editor also needs that
host-runtime check.

Store the encoded document, not `Jido.Flow.Compiled`, a raw struct map, or an
Instruction.
