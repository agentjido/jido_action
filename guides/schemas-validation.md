# Schemas And Validation

Actions and flows use Zoi schemas. `schema` validates input maps, and
`output_schema` validates normal successful output maps.

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

If no validation is needed, omit `schema` or use the empty default, `[]`.

Action and Flow schemas must accept map-shaped data. A scalar root schema such
as `Zoi.integer()` is not valid for an action or Flow boundary.

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

`Jido.Exec` calls `validate_output/1` for a normal successful result. The third
value in a three-element action tuple is extras data. Output validation does not
change it.

Use `Jido.Action.Output` for an intentional non-map success value. An output
envelope has its own validation and bypasses the normal map output schema.

## Unknown Keys

Action validation is intentionally open. Only declared keys are checked; unknown keys are merged back into the validated map.

```elixir
schema = Zoi.object(%{name: Zoi.string()})

{:ok, %{name: "Ada", request_id: "req-1"}} =
  MyAction.validate_params(%{name: "Ada", request_id: "req-1"})
```

This keeps request metadata available without forcing every action to model
every caller-owned key. Flow input and output validation use the same open
behavior.

## Flow Schemas

A Flow module declares schemas in the same form as an action:

```elixir
use Jido.Flow,
  name: "user_summary",
  schema: Zoi.object(%{user_id: Zoi.string()}),
  output_schema:
    Zoi.object(%{
      user_id: Zoi.string(),
      summary: Zoi.string()
    })
```

`Jido.Exec` validates Flow input before it compiles the runtime workflow. It
validates the resolved return expression after execution.

Stored Flow maps do not contain schemas. Attach both schemas when you load a
stored map:

```elixir
{:ok, flow} =
  Jido.Flow.from_map(stored,
    actions: actions,
    schema: input_schema,
    output_schema: output_schema
  )
```

## Static Schema Data

Action and Flow modules store their schemas at compile time. Schemas cannot
contain anonymous functions, lazy schemas, process values, or other runtime
data.

Use a named MFA for a refinement or transform:

```elixir
schema:
  Zoi.object(%{
    name: Zoi.string() |> Zoi.refine({__MODULE__, :not_blank, []})
  })

def not_blank(value, _opts) do
  if String.trim(value) == "", do: {:error, "cannot be blank"}, else: :ok
end
```

## Errors

Validation failures return `Jido.Action.Error.InvalidInputError`.

```elixir
case MyAction.validate_params(params) do
  {:ok, validated} -> {:ok, validated}
  {:error, error} -> {:error, Exception.message(error)}
end
```

The error details identify the validation phase and subject. They also contain
normalized Zoi error data.
