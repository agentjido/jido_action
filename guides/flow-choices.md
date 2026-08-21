# Flow Choices

A Choice routes one Flow node to one action or nested Flow. It tests its
options in source order, runs the first matching target, and uses a required
fallback when no option matches.

Use a Choice when the route is part of the Flow definition. Do not use it as
error recovery. A Choice selects a target before that target runs.

## Define A Choice

Use `choose`, `option`, and `otherwise` inside a `flow` block.

```elixir
defmodule MyApp.Flows.RouteShipment do
  use Jido.Flow,
    name: "route_shipment",
    schema:
      Zoi.object(%{
        order_id: Zoi.string(),
        tier: Zoi.atom(),
        item_count: Zoi.integer()
      }),
    output_schema: Zoi.map()

  alias MyApp.Actions.{BulkShipping, PriorityShipping, StandardShipping}

  flow do
    route =
      choose :shipping_route do
        option(:priority,
          when: eq(input(:tier), value(:priority)),
          run: PriorityShipping,
          with: %{order_id: input(:order_id)}
        )

        option(:bulk,
          when: gte(input(:item_count), value(100)),
          run: BulkShipping,
          with: %{
            order_id: input(:order_id),
            item_count: input(:item_count)
          }
        )

        otherwise(
          run: StandardShipping,
          with: %{order_id: input(:order_id)}
        )
      end

    return(route)
  end
end
```

Every option requires these fields:

- A unique option name.
- `when:` with a data-only condition.
- `run:` with an action or Flow module.
- `with:` with the selected target input.

`otherwise` requires `run:` and `with:`. A Choice must contain at least one
option and exactly one fallback.

## Understand Selection

Choice selection has these rules:

1. Jido evaluates options in authored order.
2. The first true condition wins.
3. Jido does not evaluate later conditions after a match.
4. Jido uses `otherwise` when no option matches.
5. Jido runs only the selected target.

A Choice is one named Flow node. Its result is the selected action result.
Downstream nodes do not need to know which target ran.

```elixir
flow do
  route =
    choose :shipping_route do
      option(:priority,
        when: eq(input(:tier), value(:priority)),
        run: MyApp.Actions.PriorityShipping,
        with: %{order_id: input(:order_id)}
      )

      otherwise(
        run: MyApp.Actions.StandardShipping,
        with: %{order_id: input(:order_id)}
      )
    end

  notified =
    step(:notify, MyApp.Actions.NotifyShipment,
      with: %{
        order_id: input(:order_id),
        carrier: select(route, :carrier)
      }
    )

  return(notified)
end
```

## Use Condition Primitives

Choice conditions are data. They cannot call arbitrary functions.

| Primitive | Meaning | Operand rule |
| --- | --- | --- |
| `eq(left, right)` | Equal | Uses Elixir equality. |
| `neq(left, right)` | Not equal | Uses Elixir inequality. |
| `lt(left, right)` | Less than | Both values must be numbers or both must be strings. |
| `lte(left, right)` | Less than or equal | Both values must be numbers or both must be strings. |
| `gt(left, right)` | Greater than | Both values must be numbers or both must be strings. |
| `gte(left, right)` | Greater than or equal | Both values must be numbers or both must be strings. |
| `left in right` | List membership | The right value must be a proper list. |
| `all([...])` | All child conditions are true | Requires at least one child condition. |
| `any([...])` | At least one child condition is true | Requires at least one child condition. |
| `not(condition)` | Inverts one condition | Requires exactly one child condition. |

`all` and `any` short-circuit. For example, `all` stops at its first false
child, and `any` stops at its first true child.

```elixir
option(:priority_api,
  when:
    all([
      eq(input(:tier), value(:priority)),
      eq(context(:source), value(:api)),
      not(eq(input(:suspended?), value(true)))
    ]),
  run: MyApp.Actions.PriorityShipping,
  with: %{order_id: input(:order_id)}
)
```

Use the normal Flow expressions as condition operands:

- `input(path)` reads Flow input.
- `context(path)` reads runtime context.
- `value(term)` adds static data.
- `result(node, path)` reads an earlier node result.
- `select(source, path)` projects from another expression.

A missing path resolves to `nil`. For example,
`eq(input(:missing), context(:missing))` is true when both paths are absent.

## Create Dependencies

A result reference in a condition or target input creates a dependency on that
node. Use `after:` when ordering is required but no data reference exists.

```elixir
flow do
  step(:classify, MyApp.Actions.ClassifyOrder,
    with: %{order_id: input(:order_id)}
  )

  route =
    choose :shipping_route, after: :classify do
      option(:priority,
        when: eq(input(:tier), value(:priority)),
        run: MyApp.Actions.PriorityShipping,
        with: %{order_id: input(:order_id)}
      )

      otherwise(
        run: MyApp.Actions.StandardShipping,
        with: %{order_id: input(:order_id)}
      )
    end

  return(route)
end
```

Jido resolves only the selected target input. However, references in every
option and in the fallback are part of the static graph. Their predecessor
nodes run before the Choice can become ready, even when their target is not
selected.

## Build A Choice As Data

Use `Jido.Flow.Builder` when code must assemble the Flow outside a module DSL.

```elixir
alias Jido.Flow.Builder

builder =
  Builder.new(name: "route_shipment")
  |> Builder.choice(
    :shipping_route,
    [
      Builder.option(
        :priority,
        Builder.eq(Builder.input(:tier), Builder.value(:priority)),
        MyApp.Actions.PriorityShipping,
        %{order_id: Builder.input(:order_id)}
      )
    ],
    Builder.fallback(
      MyApp.Actions.StandardShipping,
      %{order_id: Builder.input(:order_id)}
    ),
    bind: :route
  )
  |> Builder.return(Builder.binding(:route))

{:ok, flow} = Builder.build(builder)
```

`Jido.Flow.Syntax` provides the same constructors when you need the lower-level
authoring representation.

## Execute And Inspect A Choice

Run the Flow normally through `Jido.Exec.run/4`:

```elixir
{:ok, shipment} =
  Jido.Exec.run(
    MyApp.Flows.RouteShipment,
    %{order_id: "ord-123", tier: :priority, item_count: 2},
    %{source: :api}
  )
```

Step-wise execution exposes the Choice name, not its internal options:

```elixir
{:ok, execution} =
  Jido.Exec.start(
    MyApp.Flows.RouteShipment,
    %{order_id: "ord-123", tier: :priority, item_count: 2}
  )

["shipping_route"] = Jido.Exec.ready(execution)

{:ok, choice_result, execution} =
  Jido.Exec.step(execution, "shipping_route")

:ok = choice_result.status
shipment = choice_result.output
```

Choice node telemetry identifies the node as `kind: :choice`. Its stop event
also includes the selected option and target module. Target validation and
execution errors include the Choice node, option, target, and failure phase.

For more execution details, see [Executing Flows](flow-execution.md).
