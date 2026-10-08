# Flows

A `Jido.Flow` is a named graph of components. Each component does one kind of
work, usually by calling an Action. References connect components to Flow
input and to each other. One required `output` expression selects the value
that the Flow returns.

A Flow is data. It does no work until `Jido.Exec` runs it.

## A Small Flow

```elixir
defmodule MyApp.Actions.Price do
  use Jido.Action,
    name: "price",
    schema: Zoi.object(%{quantity: Zoi.integer(), unit_price: Zoi.integer()})

  @impl true
  def run(%{quantity: quantity, unit_price: unit_price}, _context) do
    {:ok, %{total: quantity * unit_price}}
  end
end

defmodule MyApp.Flows.Quote do
  use Jido.Flow,
    name: "quote",
    schema: Zoi.object(%{quantity: Zoi.integer(), unit_price: Zoi.integer()})

  flow do
    step "price",
      action: MyApp.Actions.Price,
      params: %{quantity: input(:quantity), unit_price: input(:unit_price)}

    step "discount", total <- result("price", :total) do
      {:ok, %{total: total, discounted: div(total * 9, 10)}}
    end

    output result("discount")
  end
end

{:ok, %{total: 300, discounted: 270}} =
  Jido.Exec.run(MyApp.Flows.Quote, %{quantity: 3, unit_price: 100})
```

- `input(:quantity)` reads Flow input.
- `result("price", :total)` reads the `:total` field of the `"price"` result
  and makes `"discount"` depend on `"price"`.
- The `"discount"` step has an inline body that compiles to an Action.
- `output result("discount")` is the Flow's return value.

## Dependencies And Order

References create dependencies. A component that reads `result("price")` runs
after `"price"`. Use `needs: ["name"]` when one component must wait for
another without reading its data.

Source order never creates a dependency. Components that do not depend on each
other can run at the same time when you pass `max_concurrency:` above `1`.
Results and effects keep a deterministic order either way. See
[Dependencies And Parallel Work](flow-dependencies.livemd).

## Components

| Component | Does | Returns |
| --- | --- | --- |
| `step` | Calls one Action, or one child Flow, or an inline body. | The Action's result, or the child Flow's output. |
| `choice` | Runs the first option whose condition is true, or the fallback. | The selected Action's result. |
| `map` | Calls one Action for each item of a collection. | A list in item order. |
| `reduce` | Folds a collection through one Action, in order. | The final accumulator. |
| `iterate` | Repeats one Action with local state until a condition ends it. | `%{kind: :jido_flow_iterate_result, iterations:, state:, output:}` |
| `dispatch` | Lets an Action choose the next Action or Flow at runtime. | The final result of the chosen path. |

Each component has a unique string name, optional `needs:`, and optional
`meta:` data. A Flow can have at most one `dispatch`, and it must be the last
component. Each component has its own guide: [Steps](flow-steps.livemd),
[Choices](flow-choices.livemd), [Map And Reduce](flow-collections.livemd),
[Iterate](flow-iterate-state.livemd), [Nested Flows](nested-flows.livemd), and
[Dynamic Flows](dynamic-flows.md).

## Values, References, And Expressions

Component fields such as `params`, `condition`, and `output` hold Flow
values. A Flow value is one of:

- literal data: numbers, strings, atoms, Booleans, `nil`, lists, and maps;
- a reference, such as `input(:id)`, `context(:tenant)`, or `result("load")`;
- a `Jido.Expr` operation, such as `input(:count) > 0`.

Expressions are a small, data-only subset of Elixir: comparisons, Boolean
operators, arithmetic, `in`, and `<>`. They cannot call functions. Put real
work in an Action or an inline body. See
[References And Data](flow-references.livemd) and
[Expressions](flow-expressions.md).

## Flow Input And Output

`schema:` validates Flow input before any work starts. `output_schema:`
validates the output value after the last component finishes. Both are Zoi
schemas, the same as Action schemas. See
[Schemas And Validation](schemas-validation.md).

Make `output` a map. A Flow module whose output is not a map fails at runtime
with `details.phase == :flow_output`. Return `Jido.Action.Output` from an
Action when the Flow must return an intentional non-map value.

## Choose An Authoring Form

All three forms produce the same `%Jido.Flow{}` value and use the same
validation rules.

| Form | Choose it when | Start with |
| --- | --- | --- |
| Module DSL | You write the Flow in your code base. This is the default. | [Flow DSL Tour](flow-language.livemd) |
| Data definition | Your code builds the graph from runtime data. | [Flow Data Definitions](flow-data.md) |
| Stored JSON | A database, a UI, or an AI model supplies the Flow. | [Store Flows As JSON](flow-storage.md) |

Only the module DSL supports inline bodies and
[extensions](flow-modules.md#add-authoring-macros). Data definitions and
JSON reference existing Action modules. JSON names them through a
`Jido.Flow.Registry` that your application owns, so stored data cannot load
arbitrary modules or create atoms.

## Validate And Inspect

```elixir
flow = MyApp.Flows.Quote.flow()

{:ok, flow} = Jido.Flow.validate(flow)
{:ok, dependencies} = Jido.Flow.dependencies(flow)
{:ok, explanation} = Jido.Flow.explain(flow)
{:ok, identity} = Jido.Flow.semantic_identity(flow)
{:ok, %Runic.Workflow{}} = Jido.Exec.compile(flow)
```

`validate/1` checks structure, references, expressions, and cycles without
loading target modules. `Jido.Exec.compile/2` also checks every Action and
child Flow. Neither runs Action work. See [Inspect Flows](flow-inspection.md).

## Run A Flow

Run a Flow module, a `%Jido.Flow{}` value, or an Instruction that targets one:

```elixir
Jido.Exec.run(MyApp.Flows.Quote, %{quantity: 3, unit_price: 100})
Jido.Exec.run(flow, %{quantity: 3, unit_price: 100}, %{}, max_concurrency: 4)
MyApp.Flows.Quote.run(%{quantity: 3, unit_price: 100}, %{})
```

Effects that Actions return are collected across the Flow and returned with
the output. A failure anywhere returns `{:error, exception}` and no effects.
See [Execution](execution.md) and [Outputs And Effects](action-effects.livemd).
