# Store Flows As JSON

`Jido.Authoring` converts a canonical `%Jido.Flow{}` to a JSON-compatible
document and back. It is the only supported way to store a Flow.

A stored document never contains module names, schemas, or atoms. It contains
string identifiers. A `Jido.Authoring.Registry` that your application owns maps each
identifier to a trusted Action, Flow, schema, or atom.

## Define A Flow To Store

The examples in this guide store this Flow:

```elixir
defmodule MyApp.Actions.CreateGreeting do
  use Jido.Action,
    id: "actions/create-greeting",
    name: "create_greeting",
    schema: Zoi.object(%{name: Zoi.string()})

  @impl true
  def run(%{name: name}, _context), do: {:ok, %{message: "Hello, " <> name <> "!"}}
end

defmodule MyApp.Flows.Greeting do
  use Jido.Flow,
    id: "flows/greeting",
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

defmodule MyApp.GreetingAuthoringVocabulary do
  def __jido_authoring__ do
    [
      %{
        id: "schemas/greeting/input/v1",
        kind: :schema,
        vsn: 1,
        target: MyApp.Flows.Greeting.schema()
      },
      %{id: "atoms/name", kind: :atom, vsn: 1, target: :name},
      %{id: "atoms/owner", kind: :atom, vsn: 1, target: :owner}
    ]
  end
end
```

## Encode And Decode

The active Registry must contain the Action, input schema, and atoms used by
this Flow. Configure these entries as described in
[Authoring Runtime Data](authoring.md#configure-discovery).

After Discovery includes the application vocabulary, use the common Authoring
boundary:

```elixir
:ok =
  Jido.Discovery.refresh(
    applications: [:jido_action],
    modules: [
      MyApp.Actions.CreateGreeting,
      MyApp.Flows.Greeting,
      MyApp.GreetingAuthoringVocabulary
    ]
  )

registry = Jido.Discovery.registry()
flow = MyApp.Flows.Greeting.flow()

{:ok, document} = Jido.Authoring.encode(flow)
{:ok, json} = Jido.Authoring.encode_json(flow)
{:ok, ^flow} = Jido.Authoring.decode_json(json)

{:ok, %{message: "Hello, Ada!"}} = Jido.Exec.run(flow, %{name: "Ada"})
```

Encoding validates the canonical Flow and requires a Registry reference for
every target, schema, and non-Boolean atom. It does not check target contracts.
Use `Jido.Exec.compile/1` for that check.

## Document Format

The document root has these fields:

```elixir
%{"type" => "jido.flow", "vsn" => 1, "name" => "greeting"} =
  Map.take(document, ["type", "vsn", "name"])

["components", "description", "name", "output", "schema", "type", "vsn"] =
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
| `{"$type": "atom", "id": "atoms/name", "vsn": 1}` | An atom, resolved through the Registry. |
| `{"$type": "map", "entries": [{"key": ..., "value": ...}]}` | A map. Each key and value uses the same encoding. |

Strings, numbers, Booleans, `null`, and lists are written as plain JSON.
Because maps use their own tag, a literal map with a `$expr` key is never read
as an operation.

The writer and reader use document `vsn` 1 for all current features,
including `$expr` operations. Other `vsn` values are rejected. The document
`vsn` is separate from the semantic identity version.

Stored components use canonical call records instead of the `step` and
`subflow` records in the [data authoring form](flow-data.md#component-kinds).
Documents use string keys and fixed string kinds. A call record contains `"kind"`,
`"target"`, and `"params"`. Its target is a Registry reference with `"id"`
and `"vsn"`. A Dispatch
expander contains only `"kind"` and `"target"`.

```elixir
[greet] = document["components"]
"call" = greet["kind"]
"action" = greet["call"]["kind"]
%{"id" => "actions/create-greeting", "vsn" => 1} = greet["call"]["target"]
["call", "kind", "meta", "name", "needs"] = Enum.sort(Map.keys(greet))
```

Do not hand-edit a `Jido.Flow.to_map/1` result into a stored document. Only
`Jido.Authoring` output is a valid document.

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

defmodule MyApp.InlineAuthoringVocabulary do
  def __jido_authoring__ do
    [
      %{
        id: "actions/greeting/normalize/v1",
        kind: :action,
        vsn: 1,
        target: MyApp.Flows.InlineGreeting.step_action("normalize")
      },
      %{
        id: "actions/greeting/greet/v1",
        kind: :action,
        vsn: 1,
        target: MyApp.Flows.InlineGreeting.step_action("greet")
      },
      %{
        id: "schemas/greeting/input/v1",
        kind: :schema,
        vsn: 1,
        target: MyApp.Flows.InlineGreeting.schema()
      },
      %{id: "atoms/name", kind: :atom, vsn: 1, target: :name}
    ]
  end
end

:ok =
  Jido.Discovery.refresh(
    applications: [:jido_action],
    modules: [MyApp.InlineAuthoringVocabulary]
  )

inline_flow = MyApp.Flows.InlineGreeting.flow()
{:ok, inline_document} = Jido.Authoring.encode(inline_flow)
{:ok, ^inline_flow} = Jido.Authoring.decode(inline_document)
{:ok, %{message: "Hello, Ada!"}} = Jido.Exec.run(inline_flow, %{name: " Ada "})
```

The stored Steps contain only identifiers and data:

```elixir
[normalize, greet] = inline_document["components"]
%{"id" => "actions/greeting/greet/v1", "vsn" => 1} = greet["call"]["target"]
["call", "kind", "meta", "name", "needs"] = Enum.sort(Map.keys(greet))

%{
  "$type" => "map",
  "entries" => [
    %{
      "key" => %{"$type" => "atom", "id" => "atoms/name", "vsn" => 1},
      "value" => %{
        "$ref" => %{
          "source" => "input",
          "component" => nil,
          "path" => [%{"$type" => "atom", "id" => "atoms/name", "vsn" => 1}]
        }
      }
    }
  ]
} = normalize["call"]["params"]
```

Deploy the owning Flow module and its generated Actions together. Keep
identifiers under your control; do not use the generated module name as the
public identifier.

A body change can keep the same target and semantic graph identity. Neither
the document nor its identity is a code snapshot. Select the application
release and Registry references that can run stored work. See
[Inline Steps](inline-actions.md).

## Flow Validation

The shared Authoring boundary checks JSON, limits, document routing, and
Registry references. The Flow decoder then rejects unknown fields, invalid
tagged values, invalid components, missing output, unknown graph references,
cycles, and invalid Dispatch placement.

Decode does not run Actions or check that resolved modules implement their
contracts. Call `Jido.Exec.compile/1` after a valid decode.

## Diagnose An Editor Draft

`Jido.Authoring.decode/2` returns ordered issues, so an editor can show them
together:

```elixir
draft =
  put_in(
    document,
    ["components", Access.at(0), "call", "target"],
    %{"id" => "actions/missing", "vsn" => 1}
  )

{:error, issues} = Jido.Authoring.decode(draft, registry: registry)

[%Jido.Authoring.Issue{path: path, message: message} | _] = issues
```

Each issue has a JSON `path` when one applies. The issue list retains source
order and JSON-compatible details.

Diagnosis uses the same field rules and error order as data authoring:

1. UTF-8, size, collection size, and nesting safety checks, followed by
   document type and `vsn` checks. A failure is terminal.
2. Unknown fields, root configuration, components in list order, and output.
   Each component checks its common fields, then its kind-specific fields.
   Registry and tagged-value errors keep their position in that field order.
3. Required output and graph checks, after valid field data. Graph checks
   report duplicate names, unknown references, cycles, and Dispatch rules.
   Unknown-reference errors hide the derived cycle error.

JSON paths are recorded during reading. Semantic validation uses those paths
without a second search of the document. A missing output is also reported
when other field errors are present.

Fix the reported errors and diagnose again to see the next phase. Diagnosis
never returns a partial Flow. It does not check whether resolved modules are
executable; call `Jido.Exec.compile/1` after a valid decode for that check.

Store the encoded document, not a compiled workflow, a raw struct map, or an
Instruction.
