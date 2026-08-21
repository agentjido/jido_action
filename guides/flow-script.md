# Authoring Flows With Flow Script

Flow Script is a text authoring surface for a Flow. `Jido.Flow.parse/2` reads
the source and returns the canonical `%Jido.Flow{}` artifact. It does not
execute the Actions in the source.

The module DSL, Flow Script, and [the runtime Builder](flow-builder.md) lower
to the same Flow data type. The language primitives are covered in [Flow
Language](flow-language.livemd), and [Flow Choices](flow-choices.livemd) covers
ordered routing.

## Parse A Complete Flow

The default parser profile is `:trusted`. In this profile, Action modules can
be written as module aliases or fully qualified module names.

```elixir
source = """
flow do
  added =
    step :add_one, MyApp.Actions.Add,
      with: %{value: input(:value), amount: value(1)}

  doubled =
    step :double, MyApp.Actions.Multiply,
      with: %{value: select(added, :value), amount: value(2)}

  return %{
    value: select(doubled, :value),
    original: input(:value),
    trace_id: context(:trace_id)
  }
end
"""

{:ok, flow} =
  Jido.Flow.parse(source,
    name: "double_after_increment",
    description: "Adds one, then doubles the result",
    schema: Zoi.object(%{value: Zoi.integer()}),
    output_schema: Zoi.object(%{
      value: Zoi.integer(),
      original: Zoi.integer(),
      trace_id: Zoi.string()
    })
  )

{:ok, %{value: 8, original: 3, trace_id: "trace-1"}} =
  Jido.Exec.run(flow, %{value: 3}, %{trace_id: "trace-1"})
```

Parser options and Flow options share the same keyword list. `profile` and
`actions` configure parsing. Other options such as `name`, `description`,
`schema`, and `output_schema` configure the Flow.

## Stored Profile And Action Registries

Use `profile: :stored` for source that comes from storage or another data
boundary. Stored source uses registry identifiers instead of direct Action
modules:

```elixir
source = """
flow do
  added =
    step :add_one, "add",
      with: %{value: input(:value), amount: value(1)}

  return added
end
"""

{:ok, flow} =
  Jido.Flow.parse(source,
    name: "stored_math",
    profile: :stored,
    actions: %{
      "add" => MyApp.Actions.Add
    },
    schema: Zoi.object(%{value: Zoi.integer()}),
    output_schema: Zoi.object(%{value: Zoi.integer()})
  )
```

The registry must be a map or keyword list whose identifiers are strings or
atoms and whose values are Action modules. Atom identifiers are normalized to
strings. A stored step must use a registered identifier. A direct module name
is rejected in the stored profile.

The stored profile parses with `existing_atoms_only: true`. It can use atoms
that already exist, such as `:add_one`, but it does not create new atoms from
untrusted source. New names should be written as strings when needed.

## Parsing Is Not Evaluation

The parser calls `Code.string_to_quoted/2` to obtain Elixir AST, then accepts
the supported `flow do` forms and lowers them into a canonical Flow. It does
not evaluate or compile the source as arbitrary Elixir code.

Parsing still does not make Action effects safe. A stored profile reduces the
accepted source surface and controls Action lookup. It is not a general
sandbox for effects in Actions that are later executed. Treat Action modules,
registries, input, and execution as separate security boundaries. See
[Security](security.md).

## Errors

`parse/2` returns `{:ok, flow}` or `{:error, exception}`. Errors include invalid
source syntax, unsupported forms, invalid parser options, unknown stored Action
identifiers, and invalid Flow structure. The error details include source
location when available.

```elixir
{:error, error} = Jido.Flow.parse("not a flow", name: "bad")
IO.puts(Exception.message(error))
```

The returned value is always a canonical `%Jido.Flow{}`. You can inspect it
with [Flow inspection](flow-inspection.md), store it with
[`Jido.Flow.to_map/2`](flows.md), or execute it with
[`Jido.Exec.run/4`](flow-execution.livemd).
