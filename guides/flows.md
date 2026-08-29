# Flows

A `Jido.Flow` is the canonical authoring value for a local workflow. It is
Action-compatible and lowers to native Runic workflow data for execution.

## Canonical Value

A Flow has six fields:

| Field | Type | Purpose |
| --- | --- | --- |
| `name` | string | Stable human-readable name. |
| `description` | string or `nil` | Optional description. |
| `schema` | static Zoi schema or `[]` | Input contract. |
| `output_schema` | static Zoi schema or `[]` | Output contract. |
| `components` | ordered component list | Author-declared graph data. |
| `output` | expression | Required Flow result. |

The component types are:

- `Jido.Flow.Step` for one Action call;
- `Jido.Flow.Subflow` for one child Flow module;
- `Jido.Flow.Choice` for ordered routing with a required fallback;
- `Jido.Flow.Map` for ordered fan-out and fan-in;
- `Jido.Flow.Reduce` for a serial left fold; and
- `Jido.Flow.Iterate` for a bounded local loop; and
- `Jido.Flow.Dynamic` for one choice at the end of a Flow.

Each component has a name, explicit `after` dependencies, and portable `meta`
data. Data references create inferred dependencies. Jido keeps explicit and
inferred dependencies separate.

A Flow can have at most one Dynamic component. Dynamic must be the last
component, and the Flow output must be the complete Dynamic result. Its
decision Action returns data for its expander Action. A normal expander result
completes the Flow. `{:continue, input, target}` ends the Flow and selects the
next executable for the same `Jido.Exec.run/4` call.

Dynamic is not available through step-wise execution or as part of a Subflow.
These limits keep continuation in one complete Exec call. See
[Continue to Another Executable](continuations.md).

## One Expression Grammar

Expressions contain portable scalar values, proper lists, maps, and
`Jido.Flow.Ref` values. Conditions use `Jido.Flow.Condition` with these
operators:

```text
eq  neq  lt  lte  gt  gte  in  all  any  not
```

References can read Flow input, context, prior component results, and
component-local Map, Reduce, or Iterate values. A reference is valid only in
its defined scope.

The authoring grammar permits any expression at `output`. At execution, a
normal Flow result must be a map. Use `Jido.Action.Output` when a Flow must
return an intentional raw, stream, batch, or opaque value.

## Four Authoring Forms

All supported forms produce the same canonical value:

1. a module that uses `Jido.Flow`;
2. direct construction with `Jido.Flow.new/1` and component constructors;
3. `Jido.Flow.Builder` for runtime construction; and
4. `Jido.Flow.Codec.decode/2` for stored JSON data.

The module DSL is the normal source-code API. Direct constructors are also an
official API. Builder and Codec input pass through the same canonical
validation.

## Author Data And Runtime Data

A Flow stores author intent. `Jido.Flow.compile/2` derives a
`Jido.Flow.Compiled` value with a native `Runic.Workflow`, component indexes,
source locations, and a compilation digest. Do not store the compiled value.

`Jido.Exec` compiles and runs a Flow. Step-wise execution exposes native
`Runic.Workflow.Runnable` values, including support work such as Join,
InputBinding, FanOut, and FanIn.

## Validation And Inspection

```elixir
{:ok, flow} = Jido.Flow.validate(flow)
{:ok, flow} = Jido.Flow.validate_executable(flow)
{:ok, dependencies} = Jido.Flow.dependencies(flow)
{:ok, explanation} = Jido.Flow.explain(flow)
{:ok, identity} = Jido.Flow.semantic_identity(flow)
```

`validate/1` is inert and does not load or check target modules.
`validate_executable/1` also checks Action and child Flow contracts. Neither
function runs Action work.

Continue with [Flow DSL](flow-language.livemd),
[Direct Construction And Builder](flow-builder.md), and
[Store Flows As JSON](flow-storage.md).
