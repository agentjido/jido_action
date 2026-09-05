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

Condition migration keeps these IDs when the registered values are unchanged.
Semantic identity version 2 requires new Flow digests and cache entries, not
new Registry IDs. Decode legacy condition documents with their trusted Registry
before writing the current operation format. See the
[beta migration notes](flow-expressions.md#migrate-earlier-v3-beta-conditions).

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

## Store A Compiled Inline Step

First define `FirstFlow.Greeting` from [Build Your First Flow](build-your-first-flow.livemd).
The host registers its compiled Actions under application-owned identifiers.
Named binding keys, such as `:name`, also need atom identifiers.

```elixir
registry =
  Jido.Flow.Registry.new!(%{
    "actions/greeting/normalize/v1" => {:action, FirstFlow.Greeting.step_action("normalize")},
    "actions/greeting/greet/v1" => {:action, FirstFlow.Greeting.step_action("greet")},
    "schemas/greeting/input/v1" => {:schema, FirstFlow.Greeting.schema()},
    "schemas/greeting/output/v1" => {:schema, FirstFlow.Greeting.output_schema()},
    "atoms/name" => {:atom, :name}
  })

flow = FirstFlow.Greeting.flow()
{:ok, document} = Jido.Flow.Codec.encode(flow, registry)
json = JSON.encode!(document)
{:ok, restored} = Jido.Flow.Codec.decode(JSON.decode!(json), registry)

true = restored == flow
{:ok, %{message: "Hello, Ada!"}} = Jido.Exec.run(restored, %{name: " Ada "})
```

This example uses Elixir's built-in `JSON` module. No new stored format is
needed. The encoded Steps still contain only these version 1 fields:

```elixir
%{"type" => "jido.flow", "version" => 1} = document
[normalize, greet] = document["components"]
"actions/greeting/greet/v1" = greet["action"]
["action", "after", "kind", "meta", "name", "params"] = Enum.sort(Map.keys(greet))

%{
  "$type" => "map",
  "entries" => [
    %{
      "key" => %{"$type" => "atom", "id" => "atoms/name"},
      "value" => %{
        "$ref" => %{
          "source" => "input",
          "component" => nil,
          "path" => [%{"$type" => "atom", "id" => "atoms/name"}]
        }
      }
    }
  ]
} = normalize["params"]
```

Stored JSON selects trusted deployed Actions. It cannot define a body, carry
a closure or MFA, or evaluate Elixir. Deploy both the owning Flow module and
its generated Actions. Keep identifiers under host control; do not store the
internal generated module name as the public Action identifier.

A body change can retain the same target and semantic graph identity. Neither
the stored document nor its graph identity is a code snapshot. Select the
application release and Registry version needed to run stored work.

The same Registry rule applies to portable inline roles.
Resolve each target through `Jido.Action.Inline.target!/2` with its typed host
path, then register that ordinary Action. Inline metadata and schemas belong
to the deployed target, not to stored body code. Portable inline Actions add
no Codec version. All operations, including conditions, use `$expr` and
require document version 2. The reader accepts legacy `$condition` records
in versions 1 and 2; the writer emits only `$expr` operations. See
[Portable Inline Actions](inline-actions.md) and [Expressions](flow-expressions.md).
Both APIs require `3.0.0-beta.6` or later.

## Validation And Limits

Decode first checks the stored grammar and resource limits. It rejects:

- invalid UTF-8;
- nesting deeper than 100 levels;
- one map or list with more than 10,000 items;
- a document with more than 100,000 data nodes;
- unknown or extra fields;
- unknown Registry identifiers; and
- invalid canonical Flow data.

Encode checks the completed document against the same storage limits. It
returns an error if format overhead makes the document too large or too
deep for the reader.

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
records, expressions, conditions, lists, maps, and graph references. They do
not return a partial Flow. Unknown-reference errors suppress a derived cycle
error because that cycle result would be misleading.

Document size, collection size, nesting, root type, and document version
errors are terminal. Diagnostics do not traverse a document after one of
these failures.

`diagnose/2` checks the stored and canonical Flow contract. It does not check
whether resolved Action or child Flow modules are executable. After a valid
decode, call `Jido.Flow.validate_executable/1` when the editor also needs that
host-runtime check.

Store the encoded document, not `Jido.Flow.Compiled`, a raw struct map, or an
Instruction.
