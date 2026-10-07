# Flows

A `Jido.Flow` is a declarative control program. Its leaves are Instruction
templates, its values are computed by expressions, and Actions provide its
executable behavior. `Jido.Exec` owns compilation and execution.

See [Flow Modules](flow-modules.md#generated-api) for the module API.

## Canonical Value

A Flow has six fields:

| Field | Type | Purpose |
| --- | --- | --- |
| `name` | string | Stable human-readable name. |
| `description` | string or `nil` | Optional description. |
| `schema` | static Zoi schema or `[]` | Input contract. |
| `output_schema` | static Zoi schema or `[]` | Output contract. |
| `components` | name-keyed map | Normalized graph nodes. |
| `output` | expression | Required Flow result. |

Map definitions use these component kinds:

- `:step` for one Action call;
- `:subflow` for one child Flow module;
- `:choice` for ordered routing with a required fallback;
- `:map` for ordered fan-out and fan-in;
- `:reduce` for a serial left fold;
- `:iterate` for a bounded local loop; and
- `:dispatch` for one choice at the end of a Flow.

Each author component has a name, explicit `needs` dependencies, and portable
`meta` data. The normalized graph uses the name as its map key. Data references
create inferred dependencies. Jido keeps explicit and inferred dependencies
separate.

A Flow can have at most one Dispatch component. Dispatch must be the last
component, and the Flow output must be the complete Dispatch result. Its
decision Action returns data for its expander Action. The expander selects the
next Action or Flow target. Runic adds that target to the executable graph.
See [Dynamic Flows](dynamic-flows.md).

## One Expression Grammar

Expressions contain portable scalar values, proper lists, maps, and
`Jido.Flow.Ref` values. `Jido.Expr` adds fixed Boolean, comparison, numeric,
and binary-concatenation operations. Flow fields accept these operations
directly or inside an optional `expr(...)` wrapper.

References can read Flow input, context, prior component results, and
component-local Map, Reduce, or Iterate values. A reference is valid only in
its defined scope.

Boolean references and literals are also valid conditions. Their evaluated
values must be Boolean. See [Expressions](flow-expressions.md) for the shared
helper DSL, exact operations, runtime construction, errors, and limits.

The authoring grammar permits any expression at `output`. At execution, a
normal Flow result must be a map. Use `Jido.Action.Output` when a Flow must
return an intentional raw, stream, batch, or opaque value.

## Three Authoring Forms

All supported forms produce the same canonical value:

1. a module that uses `Jido.Flow`;
2. map definitions with `Jido.Flow.new/1`; and
3. `Jido.Flow.Codec.decode/2` for stored JSON data.

The module DSL is the normal source-code API. Map definitions and Codec input
pass through the same canonical validation.

`new/1` accepts a plain map. Its `components` field contains a list of tagged
component maps. The canonical `%Jido.Flow{}` stores those components in a map
keyed by component name. Each value is a tagged node. A call node has this
shape:

```elixir
%{
  kind: :call,
  needs: [],
  meta: %{},
  call: {
    Jido.Instruction.template(:action, MyApp.Actions.Send),
    %{address: Jido.Flow.Ref.input(:address)}
  }
}
```

The tuple joins one inert Instruction template with its parameter expression.
The template identifies the Action or child Flow. `Jido.Exec` binds evaluated
parameters, context, and runtime location data when it executes the call.
Choice, Map, Reduce, Iterate, and Dispatch nodes use the same call tuple where
they invoke an Action. A Dispatch expander uses `nil` as the tuple value because
it receives the decision result directly. This internal graph shape is for
inspection. Author with the DSL or tagged component maps, and store a Flow with
`Jido.Flow.Codec`.

## Author Data And Runtime Data

A Flow stores author intent. `Jido.Exec.compile/2` derives a native
`Runic.Workflow`. Do not store the compiled value. Store the canonical Flow as
JSON and compile it after hydration.

Runic owns all runtime state. Immediate execution uses
`Jido.Exec.run/4`. Durable execution uses `Jido.Exec.start/6` with a
`Runic.Runner`. Checkpoint, stop, resume, and result inspection use the Runic
Runner API.

## Validation And Inspection

```elixir
{:ok, flow} = Jido.Flow.validate(flow)
{:ok, dependencies} = Jido.Flow.dependencies(flow)
{:ok, explanation} = Jido.Flow.explain(flow)
{:ok, identity} = Jido.Flow.semantic_identity(flow)
{:ok, %Runic.Workflow{} = workflow} = Jido.Exec.compile(flow)
```

`validate/1` is inert and does not load or check target modules.
`Jido.Exec.compile/2` also checks Action and child Flow contracts. Neither
operation runs Action work.

All authoring forms use the same graph rules. DSL errors identify the source
declaration; `new/1` and `validate/1` return the first error.

Continue with [Flow DSL](flow-language.livemd),
[Flow Data Definitions](flow-data.md), and
[Store Flows As JSON](flow-storage.md).

## Deferred Effect Requests

Return `{:ok, output, requests}` from an Action to
request effects after success. Flow collects these opaque requests in canonical
dependency order and returns the complete batch with its final output. Exec
does not execute effects. Failed execution returns no executable batch.
The optional third success element must be a proper list of effect requests.
See [Execution](execution.md#results-and-errors) for ordering, collections,
and migration.
