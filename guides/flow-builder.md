# Building Flows At Runtime

Use `Jido.Flow.Builder` when the Flow structure is known only at runtime. The
Builder creates the shared syntax artifact, then lowers it into the same
canonical `%Jido.Flow{}` used by the compile-time Spark DSL and [stored Flow
JSON](flow-storage.md). Builder calls are a data-construction API. They are not
a second source language.

## Create A Builder

`Builder.new/1` accepts Flow metadata and optional `schema` and
`output_schema` values.

```elixir
alias Jido.Flow.Builder

builder =
  Builder.new(
    name: "double_after_increment",
    description: "Adds one, then doubles the result",
    schema: Zoi.object(%{value: Zoi.integer()}),
    output_schema: Zoi.object(%{value: Zoi.integer()})
  )
```

## Add Steps And Output

`step/5` appends a named Action node. Its arguments are the Builder, node name,
Action module, input expression, and optional keyword options. `return/2`
declares the Flow output expression. The compile-time DSL calls this
declaration `output`; the Builder function name matches the canonical
`%Jido.Flow{return: ...}` field.

```elixir
builder =
  builder
  |> Builder.step(
    :add_one,
    MyApp.Actions.Add,
    %{value: Builder.input(:value), amount: Builder.value(1)}
  )
  |> Builder.step(
    :double,
    MyApp.Actions.Multiply,
    %{value: Builder.result(:add_one, :value), amount: Builder.value(2)}
  )
  |> Builder.return(Builder.result(:double))

{:ok, flow} = Builder.build(builder)
```

`result/2` accepts a node name and optional path. `select/2` projects a path
from any expression. `input/1`, `context/1`, and `value/1` create the other
common expressions. Prefer a direct result path when the source is one node.
Use `select/2` when you must project a composed expression or a list path.

## Map And Reduce Collections

`map/6` appends a Map fan-out. The collection expression must resolve to a
proper list. The item input can use `item/1`, `item_index/0`, and `item_id/0`.

`reduce/7` appends a serial Reduce fan-in. It also receives an initial
accumulator. Its item input can use `accumulator/1`.

```elixir
builder =
  builder
  |> Builder.map(
    :enrich,
    Builder.input(:items),
    MyApp.Actions.Enrich,
    %{
      item: Builder.item(),
      index: Builder.item_index(),
      item_id: Builder.item_id()
    },
    on_error: :collect_errors
  )
  |> Builder.reduce(
    :summarize,
    Builder.result(:enrich),
    Builder.value(%{total: 0}),
    MyApp.Actions.AddToTotal,
    %{
      total: Builder.accumulator(:total),
      value: Builder.item(:value)
    }
  )
```

Map options include `on_error: :fail_fast | :collect_errors`. Map and Reduce
also accept `bind`, `after`, and provenance options. See [Map and
Reduce](flow-collections.livemd) for output shapes, reference scope, and
execution rules.

## Choices And Conditions

`choice/5` appends one named Choice. Build its options with `option/4` and its
required fallback with `fallback/2`:

```elixir
builder =
  builder
  |> Builder.choice(
    :route,
    [
      Builder.option(
        :priority,
        Builder.eq(Builder.input(:tier), Builder.value(:priority)),
        MyApp.Actions.PriorityShipping,
        %{order_id: Builder.input(:order_id)}
      )
    ],
    Builder.fallback(MyApp.Actions.StandardShipping, %{order_id: Builder.input(:order_id)})
  )
```

Condition helpers are `eq`, `neq`, `lt`, `lte`, `gt`, `gte`, `in`, `all`,
`any`, and `not`. They create data expressions. The Choice evaluates them at
execution time. See [Choices and Conditions](flow-choices.livemd).

## Iterate At Runtime

The public module DSL calls this form `iterate`. The Builder works at the
canonical runtime level, where `iterate/6` appends one bounded Iterator. It
receives a State contract with `schema`, `initial`, and `update` fields. The
body input, State update, and completion condition can use `state/1`,
`iteration_index/0`, and `body_result/1`.

```elixir
state_contract = %{
  schema: Zoi.object(%{count: Zoi.integer()}),
  initial: %{count: Builder.input(:start)},
  update: %{count: Builder.body_result(:count)}
}

builder =
  builder
  |> Builder.iterate(
    :count,
    MyApp.Actions.Increment,
    %{count: Builder.state(:count), index: Builder.iteration_index()},
    state_contract,
    until: Builder.gte(Builder.state(:count), Builder.input(:target)),
    max_iterations: 100
  )
```

Use exactly one `while`, `until`, or `repeat` option in Builder data. `while`
and `until` require `max_iterations`. An Iterator with `repeat` uses its repeat
count as the bound and must not set `max_iterations`. The compile-time DSL
exposes `while` and `repeat`. See [Iterate and State](flow-iterate-state.livemd).

## Dependencies

Use `after: :node_name` or `after: [:first, :second]` in the options to add an
explicit dependency. References to earlier results also create dependencies.
Independent nodes can run at the same time when `Jido.Exec.run/4` uses
`async: true`. See [Executing Flows](flow-execution.livemd).

## Provenance

Pass `provenance: %{}` to preserve non-semantic authoring metadata. `label`,
`tags`, and `note` are also accepted Builder provenance options. Use explicit
node names and `result/2` for data references.

```elixir
builder =
  builder
  |> Builder.step(:load, MyApp.Actions.Load, %{id: Builder.input(:id)},
    label: "Load record",
    tags: [:read]
  )
  |> Builder.return(Builder.result(:load))
```

## Build And Validate

`build/1` lowers and validates the syntax. It returns `{:ok, flow}` or
`{:error, exception}`. Validation checks metadata, static data, Action
module values, duplicate names, references, dependencies, cycles, and the
output expression. `Jido.Exec` checks each Action contract before execution.

```elixir
case Builder.build(builder) do
  {:ok, flow} -> Jido.Exec.run(flow, %{value: 3}, %{})
  {:error, error} -> {:error, error}
end
```

The resulting artifact supports the public [inspection APIs](flow-inspection.md),
stored maps, and the [step-wise execution API](flow-execution.livemd).
