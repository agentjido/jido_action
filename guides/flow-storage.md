# Store Flows As JSON

`Jido.Flow.Codec` converts a canonical `%Jido.Flow{}` to a JSON-compatible
document and back. It is the only supported way to store a Flow.

A stored document never contains module names, schemas, or atoms. It contains
string identifiers. A `Jido.Flow.Registry` that your application owns maps each
identifier to a trusted Action, Flow, schema, or atom.

## Define A Flow To Store

The examples in this guide store this Flow:

```elixir
defmodule MyApp.Actions.CreateGreeting do
  use Jido.Action,
    name: "create_greeting",
    schema: Zoi.object(%{name: Zoi.string()})

  @impl true
  def run(%{name: name}, _context), do: {:ok, %{message: "Hello, " <> name <> "!"}}
end

defmodule MyApp.Flows.Greeting do
  use Jido.Flow,
    name: "greeting",
    schema: Zoi.object(%{name: Zoi.string()})

  flow do
    step "greet",
      action: MyApp.Actions.CreateGreeting,
      params: %{name: input(:name)},
      meta: %{owner: "communications"}

    output result("greet")
  end
end
```

## Build A Trusted Registry

Register every Action, child Flow, schema, and atom that the document needs.
This Flow needs its Action, its input schema, its empty output schema `[]`,
and the atoms `:name` (a params key and input path) and `:owner` (a `meta`
key).

```elixir
registry =
  Jido.Flow.Registry.new!(%{
    "actions/create-greeting" => {:action, MyApp.Actions.CreateGreeting},
    "schemas/greeting-input" => {:schema, MyApp.Flows.Greeting.schema()},
    "schemas/none" => {:schema, []},
    "atoms/name" => {:atom, :name},
    "atoms/owner" => {:atom, :owner},
    "actions/old-greeting" => {:alias, "actions/create-greeting"}
  })
```

Each typed entry is the one write identifier for its value. An `{:alias, id}`
entry is accepted only when reading, and it must point directly to a typed
entry. Use aliases to rename identifiers without breaking stored documents.
The Registry rejects two write identifiers for the same value.

Registry rules:

- Entry types are `{:action, module}`, `{:flow, module}`, `{:schema, schema}`,
  `{:atom, atom}`, and `{:alias, identifier}`.
- An identifier starts with a letter or digit and contains up to 255
  letters, digits, and `. _ / : @ -` characters.
- A Registry holds at most 10,000 entries.

Use `Jido.Flow.Codec.encode/1` when stable application identifiers are not
required:

```elixir
{:ok, document, registry} = Jido.Flow.Codec.encode(flow)
{:ok, json} = Jason.encode(document)

{:ok, decoded_document} = Jason.decode(json)
{:ok, decoded_flow} = Jido.Flow.Codec.decode(decoded_document, registry)
```

`encode/1` validates the canonical Flow, as `encode/2` does. It does not
check target contracts; `Jido.Exec.compile/2` does. It collects its Action
modules, child Flow modules, schemas, and data atoms. It assigns generated identifiers
and returns the Registry separately.

The generated identifiers are deterministic only for the exact Flow value.
They can change after a Flow, module, or schema change. Use them only for
temporary storage, tests, or transport within one application version. Keep
the Registry available until decoding is complete. Use an application-owned
Registry for durable storage.

Stored data never creates atoms, derives module names, or selects an
unregistered schema.

## Encode And Decode

```elixir
flow = MyApp.Flows.Greeting.flow()

{:ok, document} = Jido.Flow.Codec.encode(flow, registry)
json = JSON.encode!(document)

{:ok, decoded_flow} = Jido.Flow.Codec.decode(JSON.decode!(json), registry)
true = decoded_flow == flow
{:ok, %{message: "Hello, Ada!"}} = Jido.Exec.run(decoded_flow, %{name: "Ada"})
```

These examples use Elixir's built-in `JSON` module. Any JSON library works,
because the document contains only JSON-compatible data.

`encode/2` returns an error when the Registry has no identifier for a value
the Flow uses.

## Generate A Temporary Registry

When you do not need stable identifiers, `Jido.Flow.Codec.encode/1` builds a
Registry for you:

```elixir
{:ok, temporary_document, temporary_registry} = Jido.Flow.Codec.encode(flow)

{:ok, ^flow} =
  temporary_document
  |> JSON.encode!()
  |> JSON.decode!()
  |> Jido.Flow.Codec.decode(temporary_registry)
```

`encode/1` validates the Flow and its Action and child Flow contracts. It
collects the modules, schemas, and atoms, assigns identifiers such as
`"actions/generated-1"`, and returns the Registry separately.
`Jido.Flow.Registry.from_flow/1` builds the same Registry without encoding.

Generated identifiers depend on the exact Flow value. They can change when the
Flow, a module, or a schema changes. Use them only for tests, temporary
storage, or transport within one application version. Use an
application-owned Registry for durable storage.

## Document Format

The document root has these fields:

```elixir
%{"type" => "jido.flow", "version" => 1, "name" => "greeting"} =
  Map.take(document, ["type", "version", "name"])

["components", "description", "name", "output", "output_schema", "schema", "type", "version"] =
  document |> Map.keys() |> Enum.sort()
```

`components` is a list of component objects, written in dependency order and
then by name. Decoding normalizes the list the same way as `Jido.Flow.new/1`.

Values inside `params`, `meta`, `output`, and other Flow fields use these
tags:

| JSON form | Meaning |
| --- | --- |
| `{"$ref": {"source": "input", "component": null, "path": [...]}}` | A reference. `source` is `input`, `context`, `result`, `item`, `item_index`, `item_id`, `accumulator`, `state`, `iteration_index`, or `body_result`. |
| `{"$expr": {"operator": ">=", "operands": [...]}}` | A `Jido.Expr` operation. The operator is the Elixir spelling, such as `"=="`, `"and"`, `"not"`, `"+"`, or `"*"`. |
| `{"$type": "atom", "id": "atoms/name"}` | An atom, resolved through the Registry. |
| `{"$type": "map", "entries": [{"key": ..., "value": ...}]}` | A map. Each key and value uses the same encoding. |

Strings, numbers, Booleans, `null`, and lists are written as plain JSON.
Because maps use their own tag, a literal map with a `$expr` key is never read
as an operation.

The writer uses version 2 when the document contains a `$expr` operation, and
version 1 otherwise. The reader accepts both versions; version 1 rejects
`$expr`. Document versions and semantic identity versions are separate.

Do not hand-edit a `Jido.Flow.to_map/1` result into a stored document. Only
Codec output is a valid document.

## Store A Compiled Inline Step

Stored JSON cannot contain code. To store a Flow with an inline Step,
register the Action that the Step compiled to. `step_action/1` returns it:

```elixir
defmodule MyApp.Flows.InlineGreeting do
  use Jido.Flow,
    name: "inline_greeting",
    schema: Zoi.object(%{name: Zoi.string()})

  flow do
    step "normalize", name <- input(:name) do
      {:ok, %{name: String.trim(name)}}
    end

    step "greet", name <- result("normalize", :name) do
      {:ok, %{message: "Hello, " <> name <> "!"}}
    end

    output result("greet")
  end
end

inline_registry =
  Jido.Flow.Registry.new!(%{
    "actions/greeting/normalize/v1" =>
      {:action, MyApp.Flows.InlineGreeting.step_action("normalize")},
    "actions/greeting/greet/v1" => {:action, MyApp.Flows.InlineGreeting.step_action("greet")},
    "schemas/greeting/input/v1" => {:schema, MyApp.Flows.InlineGreeting.schema()},
    "schemas/none" => {:schema, []},
    "atoms/name" => {:atom, :name}
  })

inline_flow = MyApp.Flows.InlineGreeting.flow()
{:ok, inline_document} = Jido.Flow.Codec.encode(inline_flow, inline_registry)

{:ok, restored} =
  Jido.Flow.Codec.decode(JSON.decode!(JSON.encode!(inline_document)), inline_registry)

true = restored == inline_flow
{:ok, %{message: "Hello, Ada!"}} = Jido.Exec.run(restored, %{name: " Ada "})
```

The stored Steps contain only identifiers and data:

```elixir
[normalize, greet] = inline_document["components"]
"actions/greeting/greet/v1" = greet["action"]
["action", "kind", "meta", "name", "needs", "params"] = Enum.sort(Map.keys(greet))

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

Deploy the owning Flow module and its generated Actions together. Keep
identifiers under your control; do not use the generated module name as the
public identifier.

A body change can keep the same target and semantic graph identity. Neither
the document nor its identity is a code snapshot. Select the application
release and Registry version that can run stored work. See
[Inline Steps](inline-actions.md).

## Registry Functions

| Function | Use |
| --- | --- |
| `Jido.Flow.Registry.new/1`, `new!/1` | Build and validate a Registry from a map. |
| `Jido.Flow.Registry.from_flow/1` | Build a generated Registry for one Flow. |
| `Jido.Flow.Registry.resolve/3` | Resolve an identifier of a given kind, following aliases. |
| `Jido.Flow.Registry.identifier/3` | Find the write identifier for a value. |

```elixir
{:ok, MyApp.Actions.CreateGreeting} =
  Jido.Flow.Registry.resolve(registry, "actions/old-greeting", :action)

{:ok, "actions/create-greeting"} =
  Jido.Flow.Registry.identifier(registry, :action, MyApp.Actions.CreateGreeting)
```

## Validation And Limits

Decode rejects:

- invalid UTF-8;
- nesting deeper than 100 levels;
- one map or list with more than 10,000 items;
- a document with more than 100,000 data nodes;
- unknown or extra fields;
- unknown Registry identifiers; and
- invalid canonical Flow data.

Encode checks the finished document against the same limits. It returns an
error if the document would be too large or too deep to read back.

These limits do not bound HTTP bytes or the JSON parser. Apply transport and
parser limits before `decode/2`.

Decode does not run Actions or check that the resolved modules are
executable. Call `Jido.Exec.compile/1` to check target contracts, or run the
Flow with `Jido.Exec`.

## Diagnose An Editor Draft

`decode/2` returns the first error. `diagnose/2` returns every error it finds
in the current validation phase, so an editor can show them together:

```elixir
draft = put_in(document, ["components", Access.at(0), "action"], "actions/missing")

{:error, errors} = Jido.Flow.Codec.diagnose(draft, registry)

%{details: %{errors: [%{message: "unknown flow registry identifier"}]}} =
  Jido.Flow.Error.to_map(errors)
```

The error is one `%Jido.Flow.Error.Invalid{}` group. Each leaf error has a
JSON `path` when one applies. The error map lists the leaves under
`details.errors`.

Diagnosis runs in phases:

Document size, collection size, nesting, root type, unknown root field, and
document version errors are terminal. Diagnostics do not traverse a document
after one of these failures. Diagnosis then uses these phases:

1. Document size, collection size, nesting, root type, unknown root fields,
   and version. These
   errors are terminal; diagnosis stops after them.
2. Fields, Registry identifiers, components, Choice records, expressions,
   conditions, lists, and maps.
3. Graph checks, such as references to unknown components and cycles. These
   run only after phase 2 has no errors. An unknown-reference error hides the
   derived cycle error.

Fix the reported errors and diagnose again to see the next phase. Diagnosis
never returns a partial Flow. It does not check whether resolved modules are
executable; call `Jido.Exec.compile/1` after a valid decode for that check.

Store the encoded document, not a compiled workflow, a raw struct map, or an
Instruction.
