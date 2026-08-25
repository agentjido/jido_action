# Flows

A Flow is one canonical `%Jido.Flow{}` authoring value. It describes named
components and one required output expression.

```elixir
step =
  Jido.Flow.Step.new!(
    name: "double",
    action: MyApp.Actions.Double,
    params: %{value: Jido.Flow.Ref.input(:value)}
  )

flow =
  Jido.Flow.new!(
    name: "double_value",
    components: [step],
    output: Jido.Flow.Ref.result("double")
  )
```

The canonical value contains author intent only. It does not contain a Runic
workflow, effective dependencies, a topological order, runtime results, or
Spark source locations.

## Canonical components

- `Jido.Flow.Step` calls one Action.
- `Jido.Flow.Subflow` calls one Flow-compatible Action as a Flow boundary.
- `Jido.Flow.Choice` selects the first matching Action option or its required
  Action fallback.
- `Jido.Flow.Map` applies one Action to collection items.
- `Jido.Flow.Reduce` folds collection items through one Action.
- `Jido.Flow.Iterate` runs one Action in a bounded local loop.

Only a Spark `step` or `Builder.step/5` derives a Subflow. It uses the exact
`Jido.Executable` kind. Choice, Map, Reduce, and Iterate contain Action-only
slots. A Flow module in one of these slots is an executable validation error.

Every component has `name`, `after`, and `meta` fields. The `after` list stores
explicit author control order only. Result references create derived data
dependencies. Validation does not copy these dependencies into `after`.

`meta` contains portable author data. Spark file, line, and column information
is stored in the `source_map` field of `Jido.Flow.Compiled`. It does not change
the canonical Flow or its semantic identity.

## One expression grammar

Expressions contain portable scalar data, lists, maps, or `Jido.Flow.Ref`
values. Literals stay as literals. Conditions use the same expressions.

References can read Flow input, runtime context, named component results, and
component-local values. Map and Reduce add item references. Reduce adds an
accumulator reference. Iterate adds state, iteration index, and body result
references. Validation rejects a local reference outside its owner component.

## Four authoring routes

These routes produce equal canonical values:

- The unchanged Spark module DSL
- `Jido.Flow.Builder`
- `Jido.Flow.Codec.decode/2` with a trusted Registry
- Direct component and Flow construction

The Spark lowerer is a one-way syntax adapter. It creates canonical component
structs directly. The Builder also stores canonical component structs.

## Stored JSON

Use the Codec for storage:

```elixir
{:ok, document} = Jido.Flow.Codec.encode(flow, registry)
json = JSON.encode!(document)

{:ok, restored} =
  json
  |> JSON.decode!()
  |> Jido.Flow.Codec.decode(registry)

restored == flow
```

The trusted `Jido.Flow.Registry` supplies stable identifiers for Action
modules, Flow modules, schemas, and user-data atoms. The decoder does not make
atoms or derive modules from JSON strings.

## Inspection and derived data

```elixir
{:ok, dependencies} = Jido.Flow.dependencies(flow)
{:ok, explanation} = Jido.Flow.explain(flow)
{:ok, identity} = Jido.Flow.semantic_identity(flow)
semantic_map = Jido.Flow.to_map(flow)
```

Dependency inspection reports `after`, `references`, and `effective`
separately. `Jido.Flow.Compiled` is the container for derived Runic workflow
data, component indexes, compiled output selection, source data, and the
compilation digest.

```elixir
{:ok, %Jido.Flow.Compiled{} = compiled} = Jido.Flow.compile(flow)
```

`Jido.Exec` executes this native workflow. Its step-wise API exposes native
Runic Runnable values, including support work when Runic adds it.

## Continue with the Flow guides

- [Build Your First Flow](build-your-first-flow.livemd)
- [Flow Language](flow-language.livemd)
- [Map and Reduce](flow-collections.livemd)
- [Iterate and State](flow-iterate-state.livemd)
- [Stored Flow JSON](flow-storage.md)
- [Runtime Builder](flow-builder.md)
- [Nested Flows](nested-flows.livemd)
- [Flow Execution](flow-execution.livemd)
