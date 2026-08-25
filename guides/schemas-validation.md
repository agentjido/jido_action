# Schemas And Validation

Jido uses Zoi schemas for Action input and output, Flow input and output, and
Iterate State. Schemas are static module data.

## Action Schemas

```elixir
defmodule MyApp.Actions.Price do
  use Jido.Action,
    name: "price",
    schema:
      Zoi.object(%{
        quantity: Zoi.integer() |> Zoi.min(1),
        unit_price: Zoi.number()
      }),
    output_schema: Zoi.object(%{total: Zoi.number()})

  @impl true
  def run(params, _context) do
    {:ok, %{total: params.quantity * params.unit_price}}
  end
end
```

An Action schema must accept map-shaped data. `[]` means that no field schema
is applied, but the Action boundary still requires a map.

Object schemas are open at the Jido boundary. Declared fields are validated.
Unknown fields stay in the returned map.

```elixir
{:ok, validated} =
  MyApp.Actions.Price.validate_params(%{
    quantity: 2,
    unit_price: 3.5,
    request_tag: "keep"
  })

validated.request_tag
```

## Flow Schemas

A Flow module uses the same options.

```elixir
defmodule MyApp.Flows.PriceOrder do
  use Jido.Flow,
    name: "price_order",
    schema: Zoi.object(%{quantity: Zoi.integer(), unit_price: Zoi.number()}),
    output_schema: Zoi.object(%{total: Zoi.number()})

  flow do
    step "price",
      action: MyApp.Actions.Price,
      params: %{
        quantity: input(:quantity),
        unit_price: input(:unit_price)
      }

    output result("price")
  end
end
```

Flow input validation occurs before compilation work starts. Output validation
occurs after Jido evaluates the explicit output expression.

## Static Schema Rule

Action and Flow module schemas must be safe to store in compiled module data.
Anonymous functions, lazy schemas, PIDs, ports, and references are not
accepted. Use a named MFA for effects in a refinement or transform.

```elixir
Zoi.string()
|> Zoi.refine({MyApp.Validation, :not_blank, []})
```

The same static-data rule applies to Iterate State schemas and schemas placed
in a trusted Flow Registry.

## Iterate State

An Iterate State schema validates each state replacement.

```elixir
state(
  Zoi.object(%{count: Zoi.integer()}),
  initial: %{count: 0}
)
```

A rejected state stops the Iterate node. Jido does not expose the rejected
state value in a stable external error form.

## Test Both Boundaries

Test constructors and generated validation functions for data rules. Then use
`Jido.Exec.run/4` to test the complete execution boundary. Constructor
validation is inert. It never calls an Action.
