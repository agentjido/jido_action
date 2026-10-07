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
| `components` | ordered component list | Author-declared graph data. |
| `output` | expression | Required Flow result. |

The component types are:

- `Jido.Flow.Step` for one Action call;
- `Jido.Flow.Subflow` for one child Flow module;
- `Jido.Flow.Choice` for ordered routing with a required fallback;
- `Jido.Flow.Map` for ordered fan-out and fan-in;
- `Jido.Flow.Reduce` for a serial left fold; and
- `Jido.Flow.Iterate` for a bounded local loop; and
- `Jido.Flow.Dispatch` for one choice at the end of a Flow.

Each component has a name, explicit `needs` dependencies, and portable `meta`
data. Data references create inferred dependencies. Jido keeps explicit and
inferred dependencies separate.

A Flow can have at most one Dispatch component. Dispatch must be the last
component, and the Flow output must be the complete Dispatch result. Its
decision Action returns data for its expander Action. A normal expander result
completes the Flow. `{:continue, input, target}` ends the Flow and selects the
next executable for the same `Jido.Exec.run/4` call.

Dispatch is not available through step-wise execution or as part of a Subflow.
These limits keep continuation in one complete Exec call. See
[Dynamic Flows](dynamic-flows.md).

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
2. Data definitions with `Jido.Flow.new/1`, using component maps or constructors; and
3. `Jido.Flow.Codec.decode/2` for stored JSON data.

The module DSL is the normal source-code API. Direct constructors are also an
official API. Data definitions and Codec input pass through the same canonical
validation.

## Author Data And Runtime Data

A Flow stores author intent. `Jido.Flow.compile/2` delegates to Exec and derives
a `Jido.Exec.Flow.Compiled` execution plan with component indexes, source
locations, and a compilation digest. Do not store the compiled value.

`Jido.Exec` compiles and runs a Flow. Step-wise execution exposes small
`Jido.Exec.Work` descriptions, including Join, input binding, fan-out, and
fan-in support work. Select a unit with its revision-scoped token. Use
`Jido.Exec.native/1` for advanced, read-only native inspection.

## Invocation Replay

Run-to-completion calls can use the optional `Jido.Exec.Invocation` host
protocol. The protocol records normalized Action outcomes. It does not record
one whole Flow outcome or an Execution snapshot.

Replay starts the Flow in a new Exec call. Flow materialization, validation,
expressions, bindings, branching, Reduce accumulation, Iterate state updates,
and Iterate completion checks run again. At each Action position, the host can
supply a confirmed receipt. That receipt replaces Action input validation,
the Action callback, and Action output validation.

An empty Flow has no Action occurrence. It runs its normal Flow validation and
output work without an invocation host callback.

The occurrence identity includes the complete component path and the position
inside a collection or Dispatch. Map and Reduce use the zero-based source
index. Iterate uses the zero-based iteration index. Choice uses the selected
option or fallback. Dispatch identifies its decision and expander Actions.
Structural Subflows add all parent names to the component path. Thus, the same
child Flow used in two locations gets different Action occurrence keys.

Permitted continuations remain in the same complete Exec call. Each next root
target uses a larger chain index. A nested `Jido.Exec.run/4` call made inside
an Action is a separate call. The parent treats it as opaque Action work.

The host and Flow author must make orchestration deterministic for replay.
Flow cannot prove this condition. Changing context, deadlines, expressions,
validators, materializers, or state functions can select different work.
See [Replay Action Invocations](execution.md#replay-action-invocations) for the
host callbacks, receipt shapes, and recovery limits.

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
See [Execution](execution.md#results-and-errors) for ordering, collections, continuations, and migration.
