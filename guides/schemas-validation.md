# Schemas and Validation

Jido Action uses Zoi schemas for Action and Flow input and output boundaries.
`schema` validates input parameters and `output_schema` validates successful
results.

## Action Input Schema

```elixir
defmodule MyApp.Actions.CreateUser do
  use Jido.Action,
    name: "create_user",
    schema:
      Zoi.object(%{
        email:
          Zoi.string()
          |> Zoi.trim()
          |> Zoi.to_downcase()
          |> Zoi.regex(Zoi.Regexes.email()),
        age:
          Zoi.integer()
          |> Zoi.min(13)
          |> Zoi.optional()
      })

  @impl true
  def run(params, _context), do: {:ok, params}
end
```

If no validation is needed, omit `schema` or use the empty default.

Action input schemas must describe map-shaped data. `validate_params/1` returns
the validated map and preserves unknown object keys.

## Defaults

Use `Zoi.default/2` when missing fields should be filled:

```elixir
schema:
  Zoi.object(%{
    limit: Zoi.integer() |> Zoi.min(1) |> Zoi.default(50),
    sort: Zoi.enum([:asc, :desc]) |> Zoi.default(:asc)
  })
```

Use `Zoi.optional/1` when a missing field should remain absent.

## Action Output Schema

```elixir
output_schema:
  Zoi.object(%{
    id: Zoi.string(),
    status: Zoi.enum([:created, :updated])
  })
```

Call `validate_output/1` for successful `{:ok, result}` returns when the action declares an output schema. The third value in a three-tuple is preserved by the action contract.

Normal Action output is map-shaped. A successful raw, stream, batch, or opaque
value must use a `Jido.Action.Output` envelope. The envelope is validated as an
explicit output value.

## Flow Schemas

`use Jido.Flow` accepts the same `schema` and `output_schema` options:

```elixir
use Jido.Flow,
  name: "process_order",
  schema: Zoi.object(%{order_id: Zoi.string()}),
  output_schema: Zoi.object(%{status: Zoi.string()})
```

`Jido.Exec` validates Flow input before it starts nodes and validates the
declared Flow result after node execution. Flow schemas must produce map-shaped
input and output values, unless the result is an explicit output envelope.
Flow validation is separate from each node Action's validation: the Flow maps
data into node inputs, and each Action validates its own input at its node
boundary.

## Iterate State Schemas

Each Iterate State contract has a required `schema` field. Jido applies the schema
to the initial State and each complete update candidate. The validated value
must stay a plain map.

```elixir
state_contract = %{
  schema: Zoi.object(%{count: Zoi.integer()}),
  initial: %{count: Jido.Flow.Builder.value(0)},
  update: %{count: Jido.Flow.Builder.body_result(:count)}
}
```

Use `state([], initial: ...)` when the module DSL needs no additional field
validation. A stored Flow uses a stable State schema identifier from its host
contract bundle. See [Iterate and State](flow-iterate-state.livemd) and [Stored
Flow JSON](flow-storage.md).

## Unknown Keys

Action and Flow object validation is intentionally open. Only declared keys
are checked; unknown keys are merged back into the validated map.

```elixir
schema = Zoi.object(%{name: Zoi.string()})

{:ok, %{name: "Ada", request_id: "req-1"}} =
  MyAction.validate_params(%{name: "Ada", request_id: "req-1"})
```

This keeps request metadata available without forcing every action to model every caller-owned key.

## Errors

Validation failures return `Jido.Action.Error.InvalidInputError`. The error
contains a message and structured details, including the validation phase and
normalized Zoi errors when available.

```elixir
case MyAction.validate_params(params) do
  {:ok, validated} -> {:ok, validated}
  {:error, error} -> {:error, Exception.message(error)}
end
```

The error details include context, subject, and normalized Zoi error data. Use
`Jido.Action.Error.to_map/1` to serialize the stable error type and details.
