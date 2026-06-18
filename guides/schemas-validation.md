# Schemas And Validation

V3 action schemas are Zoi-only. `schema` validates input parameters and `output_schema` validates successful action results.

## Input Schema

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

## Output Schema

```elixir
output_schema:
  Zoi.object(%{
    id: Zoi.string(),
    status: Zoi.enum([:created, :updated])
  })
```

Flow steps validate output only for successful `{:ok, result}` or `{:ok, result, extra}` returns. The third value in a three-tuple is preserved.

## Unknown Keys

Action validation is intentionally open. Only declared keys are checked; unknown keys are merged back into the validated map.

```elixir
schema = Zoi.object(%{name: Zoi.string()})

{:ok, %{name: "Ada", request_id: "req-1"}} =
  MyAction.validate_params(%{name: "Ada", request_id: "req-1"})
```

This keeps request metadata available without forcing every action to model every caller-owned key.

## Errors

Validation failures return `Jido.Action.Error.InvalidInputError`.

```elixir
case MyAction.validate_params(params) do
  {:ok, validated} -> {:ok, validated}
  {:error, error} -> {:error, Exception.message(error)}
end
```

The error details include context, module, and normalized Zoi error data.
