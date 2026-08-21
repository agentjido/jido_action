# Flow Authoring Languages

Jido Flow has several authoring surfaces. Each surface creates the same
canonical `%Jido.Flow{}` artifact. The artifact, not the source language, is the
execution contract.

## Select A Surface

| Surface | Use it when |
| --- | --- |
| Flow module DSL | The graph is static application code. |
| Runtime builder | Application code creates the graph from trusted runtime choices. |
| Trusted source parser | A developer tool reads a restricted Elixir-like Flow source string. |
| Stored source profile | Stored source must use a trusted registry of action identifiers. |
| Stored map | A JSON-safe canonical artifact must cross a storage or service boundary. |

The authoring path is:

```text
Flow module DSL ─┐
Runtime builder ─┼─> Jido.Flow.Syntax ─> Lowerer ─> %Jido.Flow{}
Source parser ───┘

Stored map ─────────> Map codec ─────────────────> %Jido.Flow{}

%Jido.Flow{} ───────> Jido.Exec ─> Flow compiler ─> Runic workflow
```

The shared syntax and lowerer give all source languages the same rules for
names, references, dependencies, returns, and provenance.

The examples below all describe the same graph. Assume that
`MyApp.Actions.Add` and `MyApp.Actions.Multiply` accept `value` and `amount`
params and return `%{value: integer}`.

## Flow Module DSL

Use `use Jido.Flow` for a graph that is part of application source code.
Validation and lowering occur at compile time.

```elixir
defmodule MyApp.Flows.Math do
  use Jido.Flow,
    name: "math_flow",
    description: "Adds one and doubles the result",
    schema: Zoi.object(%{value: Zoi.integer()}),
    output_schema: Zoi.object(%{value: Zoi.integer()})

  flow do
    added =
      step(:add_one, MyApp.Actions.Add,
        with: %{value: input(:value), amount: value(1)}
      )

    doubled =
      step(:double, MyApp.Actions.Multiply,
        with: %{value: select(added, :value), amount: value(2)}
      )

    return(doubled)
  end
end

flow = MyApp.Flows.Math.flow()
```

A bound variable such as `added` is a source handle. The lowerer replaces it
with a canonical result reference. If a bound step has no explicit name, its
binding name becomes the step name.

Use `after:` for an order-only edge. Use `label:`, `tags:`, and `note:` for
provenance that must not change Flow semantics.

## Runtime Builder

Use `Jido.Flow.Builder` when trusted application code must assemble a Flow at
runtime.

```elixir
alias Jido.Flow.Builder

builder =
  Builder.new(
    name: "math_flow",
    description: "Adds one and doubles the result",
    schema: Zoi.object(%{value: Zoi.integer()}),
    output_schema: Zoi.object(%{value: Zoi.integer()})
  )
  |> Builder.step(
    :add_one,
    MyApp.Actions.Add,
    %{
      value: Builder.input(:value),
      amount: Builder.value(1)
    }
  )
  |> Builder.step(
    :double,
    MyApp.Actions.Multiply,
    %{
      value: Builder.result(:add_one, :value),
      amount: Builder.value(2)
    }
  )
  |> Builder.return(Builder.result(:double))

{:ok, flow} = Builder.build(builder)
```

The builder stores `Jido.Flow.Syntax`. `build/1` calls the shared lowerer and
returns a validated canonical Flow.

Use the builder for trusted code. Do not map untrusted module names directly to
action atoms.

## Trusted Source Parser

`Jido.Flow.parse/2` parses a restricted Elixir-like source language. It uses
the Elixir parser to obtain AST, but it does not evaluate or compile the source.

```elixir
source = """
flow do
  step :add_one, MyApp.Actions.Add,
    %{value: input(:value), amount: value(1)}

  step :double, MyApp.Actions.Multiply,
    %{value: result(:add_one, :value), amount: value(2)}

  return result(:double)
end
"""

{:ok, flow} =
  Jido.Flow.parse(source,
    name: "math_flow",
    description: "Adds one and doubles the result",
    schema: Zoi.object(%{value: Zoi.integer()}),
    output_schema: Zoi.object(%{value: Zoi.integer()})
  )
```

The parser accepts only the Flow subset. It rejects arbitrary local calls,
remote calls outside the action position, computed literals, and unsupported
assignments.

The default `:trusted` profile can resolve module aliases from source. Use it
only for trusted developer input.

## Stored Source Profile

The `:stored` parser profile replaces module names with application-defined
action identifiers. It also uses existing atoms only.

```elixir
stored_source = """
flow do
  step "add_one", "add",
    %{value: input(:value), amount: value(1)}

  step "double", "multiply",
    %{value: result("add_one", :value), amount: value(2)}

  return result("double")
end
"""

actions = %{
  "add" => MyApp.Actions.Add,
  "multiply" => MyApp.Actions.Multiply
}

{:ok, flow} =
  Jido.Flow.parse(stored_source,
    profile: :stored,
    actions: actions,
    name: "math_flow",
    description: "Adds one and doubles the result",
    schema: Zoi.object(%{value: Zoi.integer()}),
    output_schema: Zoi.object(%{value: Zoi.integer()})
  )
```

The registry is the trust boundary. The parser rejects an action identifier
that is not in the registry. It also rejects direct module aliases in stored
source.

The parser is not an authorization system. Apply application authorization,
size limits, and resource limits before stored source reaches execution.

## Direct Shared Syntax

`Jido.Flow.Syntax` is the common source representation. Advanced tools can
create it directly and call `Jido.Flow.Syntax.Lowerer.lower/1`.

```elixir
alias Jido.Flow.Syntax
alias Jido.Flow.Syntax.Lowerer

syntax =
  Syntax.new(
    name: "math_flow",
    description: "Adds one and doubles the result",
    schema: Zoi.object(%{value: Zoi.integer()}),
    output_schema: Zoi.object(%{value: Zoi.integer()})
  )
  |> Syntax.step(
    :add_one,
    MyApp.Actions.Add,
    %{value: Syntax.input(:value), amount: Syntax.value(1)}
  )
  |> Syntax.step(
    :double,
    MyApp.Actions.Multiply,
    %{value: Syntax.result(:add_one, :value), amount: Syntax.value(2)}
  )
  |> Syntax.return(Syntax.result(:double))

{:ok, flow} = Lowerer.lower(syntax)
```

Prefer `Jido.Flow.Builder` for normal runtime construction. Use direct syntax
when a language adapter must preserve source bindings or provenance before
lowering.

## Stored Canonical Maps

Use a stored map when you need JSON-safe interchange after a Flow is canonical.

```elixir
actions = %{
  "add" => MyApp.Actions.Add,
  "multiply" => MyApp.Actions.Multiply
}

stored = Jido.Flow.to_map(flow, format: :stored, actions: actions)
json = JSON.encode!(stored)
decoded = JSON.decode!(json)

{:ok, loaded} =
  Jido.Flow.from_map(decoded,
    actions: actions,
    schema: flow.schema,
    output_schema: flow.output_schema
  )
```

Stored maps use tagged expression records and registered action identifiers.
They do not embed schemas. The loader must attach the input and output schemas
from trusted application data.

## Verify Language Parity

Compare semantic maps when you implement another Flow language:

```elixir
module_flow = MyApp.Flows.Math.flow()

true =
  Jido.Flow.to_map(module_flow) ==
    Jido.Flow.to_map(flow)
```

A correct language adapter must preserve these semantics:

- Flow metadata and schemas
- node names and action modules
- nested input expressions
- result-derived and explicit dependencies
- the declared return expression

Source line data, branch labels, annotations, and authoring order can remain in
provenance. They must not change the default semantic map or semantic identity.
