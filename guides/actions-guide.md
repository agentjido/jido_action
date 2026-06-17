# Actions

An action is a module that owns one operation. It declares metadata and validation, then implements `run/2`.

## Options

```elixir
use Jido.Action,
  name: "normalize_email",
  description: "Normalizes an email address",
  schema: Zoi.object(%{email: Zoi.string()}),
  output_schema: Zoi.object(%{email: Zoi.string()})
```

Supported options:

- `:name` - required public action name.
- `:description` - optional human-readable summary.
- `:schema` - optional Zoi input schema.
- `:output_schema` - optional Zoi output schema.

## Callback

```elixir
@impl true
def run(%{email: email}, context) do
  domain = Map.get(context, :default_domain, "example.com")
  normalized = email |> String.trim() |> String.downcase()

  if String.contains?(normalized, "@") do
    {:ok, %{email: normalized}}
  else
    {:ok, %{email: normalized <> "@" <> domain}}
  end
end
```

Allowed return shapes:

- `{:ok, map}`
- `{:ok, map, extra}`
- `{:error, reason}`
- `{:error, reason, extra}`

Use three-tuples when the caller must receive an extra value alongside the result or error.

## Validation

```elixir
{:ok, params} = MyAction.validate_params(%{email: "USER@EXAMPLE.COM"})
{:ok, output} = MyAction.validate_output(%{email: "user@example.com"})
```

Only declared keys are validated. Unknown keys are preserved so callers can carry additional request data without expanding every schema.

## Execution

Prefer `Jido.Exec.run/4` for production execution:

```elixir
Jido.Exec.run(MyAction, params, context, timeout: 2_000, max_retries: 1)
```

Directly calling `run/2` is useful in narrow unit tests when validation and execution policy are not under test.

