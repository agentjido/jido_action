# Schemas And Validation

Jido uses Zoi schemas for Action input and output, Flow input and output, and
Iterate State. Schemas are static module data.

## Action Schemas

```elixir
defmodule MyApp.Actions.Price do
  use Jido.Action,
    name: "price",
    schema:
      Zoi.object(
        %{
          quantity: Zoi.integer() |> Zoi.min(1),
          unit_price: Zoi.number()
        },
        unrecognized_keys: :preserve
      ),
    output_schema: Zoi.object(%{total: Zoi.number()})

  @impl true
  def run(params, _context) do
    {:ok, %{total: params.quantity * params.unit_price}}
  end
end
```

An Action schema must accept map-shaped data. Omitted and `nil` schemas use
`Zoi.map()`. An explicit `[]` is invalid because it is not a Zoi schema.

Direct, nested, and wrapped schemas keep their declared Zoi unknown-key policy.
Zoi object schemas strip unknown keys by default. Use
`unrecognized_keys: :preserve` when an Action or Flow must retain them. Use
`:error` to reject them, or a typed preservation policy to validate and retain
them.

Struct schemas use Zoi's `:strip` or `:error` policy. Zoi does not support an
unknown-key preservation policy for structs. Declare each required struct
field, or use an object schema when arbitrary additional fields must survive.
When Zoi returns a struct, Action and Flow validation converts the complete
parsed struct to a plain map. A transform that returns a plain map or another
value keeps that result unchanged, subject to the Action and Flow map boundary.

```elixir
{:ok, validated} =
  MyApp.Actions.Price.validate_params(%{
    quantity: 2,
    unit_price: 3.5,
    request_tag: "keep"
  })

validated.request_tag
```

Set the policy on each object that must preserve unknown fields.

```elixir
Zoi.object(%{
  customer:
    Zoi.object(%{name: Zoi.string()}, unrecognized_keys: :preserve)
})
```

For complete native Signal values, see
[Typed Signals In Actions And Flow](https://github.com/agentjido/jido/blob/release/v3/guides/typed-signals.livemd). The runnable example
checks exact definitions at both Action boundaries and constructs a new request
from a previous Flow result. It also states the current JSON Schema export limit.

## String-Keyed Input

JSON decoders and Phoenix params produce maps with string keys. A
`Zoi.object/2` schema with atom keys rejects them by default. Add
`coerce: true` to the object to accept string keys for its declared fields.
Add `coerce: true` to a field to convert its value, such as `"3"` to `3`:

```elixir
schema =
  Zoi.object(
    %{
      quantity: Zoi.integer(coerce: true),
      unit_price: Zoi.number(coerce: true)
    },
    coerce: true
  )

{:ok, %{quantity: 3, unit_price: 2.5}} =
  Zoi.parse(schema, %{"quantity" => "3", "unit_price" => "2.5"})
```

The validated map uses atom keys for declared fields. When the object uses
`unrecognized_keys: :preserve`, undeclared string keys stay as strings.

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
accepted. Use a named MFA for each refinement or transform.

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

A rejected state stops the Iterate node. Jido does not add the rejected state
value to the error details.

## Test Both Boundaries

Test map definitions and generated validation functions for data rules. Then
use `Jido.Exec.run/4` to test the complete execution boundary. Flow definition
validation is inert. It never calls an Action.
