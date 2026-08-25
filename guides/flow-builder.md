# Building Flows At Runtime

Use `Jido.Flow.Builder` when runtime data defines the Flow structure. The
Builder stores canonical component structs and returns one `%Jido.Flow{}`.

## Create and build a Flow

```elixir
alias Jido.Flow.Builder

builder =
  Builder.new(
    name: "double_after_increment",
    schema: Zoi.object(%{value: Zoi.integer()}),
    output_schema: Zoi.object(%{value: Zoi.integer()})
  )
  |> Builder.step(
    "add_one",
    MyApp.Actions.Add,
    %{value: Builder.input(:value), amount: Builder.value(1)}
  )
  |> Builder.step(
    "double",
    MyApp.Actions.Multiply,
    %{value: Builder.result("add_one", :value), amount: 2}
  )
  |> Builder.output(Builder.result("double"))

{:ok, flow} = Builder.build(builder)
```

The output expression is required. `Builder.value/1` returns its literal
unchanged. It does not create a literal reference wrapper.

`Builder.step/5` resolves the exact `Jido.Executable` kind. It stores a
`Jido.Flow.Step` for an Action and a `Jido.Flow.Subflow` for a Flow. Other
Builder component functions accept Action targets only.

## Canonical options

All components accept `after` and `meta`. Map also accepts `on_error`. Iterate
also accepts `completion` and `max_iterations`.

The Builder does not accept the old `deps`, `provenance`, `return`, `while`,
`until`, or `repeat` aliases. The Spark DSL keeps its existing `while` and
`repeat` forms. Its lowerer converts them to canonical Iterate fields.

Use `after` only for explicit control order. A named result reference creates
a separate inferred dependency.

## Map and Reduce

```elixir
builder =
  builder
  |> Builder.map(
    "enrich",
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
    "summarize",
    Builder.result("enrich"),
    %{total: 0},
    MyApp.Actions.AddToTotal,
    %{
      total: Builder.accumulator(:total),
      value: Builder.item(:value)
    }
  )
```

Map and Reduce expressions can use item-local references. Only Reduce can use
an accumulator reference.

## Choice

```elixir
builder =
  Builder.choice(
    builder,
    "route",
    [
      Builder.option(
        "priority",
        Builder.eq(Builder.input(:tier), :priority),
        MyApp.Actions.PriorityShipping,
        %{order_id: Builder.input(:order_id)}
      )
    ],
    Builder.fallback(
      MyApp.Actions.StandardShipping,
      %{order_id: Builder.input(:order_id)}
    )
  )
```

Choice options and the fallback must name Actions. They cannot name Flow
modules.

## Iterate

```elixir
state =
  Jido.Flow.Iterate.State.new!(
    schema: Zoi.object(%{count: Zoi.integer()}),
    initial: %{count: Builder.input(:start)},
    update: %{count: Builder.body_result(:count)}
  )

builder =
  Builder.iterate(
    builder,
    "count",
    MyApp.Actions.Increment,
    %{count: Builder.state(:count)},
    state,
    completion: Builder.gte(Builder.state(:count), Builder.input(:target)),
    max_iterations: 100
  )
```

Iterate has a required local State value, completion condition, and positive
maximum iteration count.

## Errors

Builder functions keep the first construction error. `build/1` returns
`{:ok, flow}` or `{:error, exception}`. It validates canonical data, names,
references, explicit order, inferred dependencies, cycles, and output. Call
`Jido.Flow.validate_executable/1` when target modules must also be checked.
