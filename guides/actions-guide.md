# Jido.Action

An action is one named operation. It owns its input contract, output contract,
and `run/2` implementation. It does not own workflow structure or runtime
policy.

## Define An Action

```elixir
defmodule MyApp.Actions.NormalizeEmail do
  use Jido.Action,
    name: "normalize_email",
    description: "Normalizes an email address",
    schema:
      Zoi.object(%{
        email: Zoi.string() |> Zoi.trim() |> Zoi.to_downcase()
      }),
    output_schema:
      Zoi.object(%{
        email: Zoi.string()
      })

  @impl true
  def run(%{email: email}, context) do
    domain = Map.get(context, :default_domain, "example.com")

    normalized =
      if String.contains?(email, "@") do
        email
      else
        email <> "@" <> domain
      end

    {:ok, %{email: normalized}}
  end
end
```

The action options are:

- `:name` is the required public name. It must be a non-blank string.
- `:description` is an optional description.
- `:schema` is an optional Zoi input schema.
- `:output_schema` is an optional Zoi output schema.

Schemas must accept map-shaped action data. Schemas must also contain static
module data. Use a named MFA for a Zoi refinement or transform that needs a
function.

## Generated Functions

`use Jido.Action` generates these functions:

- `name/0` and `description/0` return metadata.
- `schema/0` and `output_schema/0` return the stored schemas.
- `validate_params/1` validates action input.
- `validate_output/1` validates successful action output.
- `run/2` is the action callback that your module overrides.

The generated validators accept and return maps. Validation is open. Declared
keys are validated, and unknown keys stay in the result.

## The Run Contract

`run/2` receives validated params and the runtime context when `Jido.Exec`
calls the action.

The callback can return one of these tuples:

- `{:ok, output}`
- `{:ok, output, extras}`
- `{:error, reason}`
- `{:error, reason, extras}`

A normal successful output must be a map. `Jido.Exec` validates this map
against `output_schema`.

Use an explicit `Jido.Action.Output` envelope for a successful raw, stream,
batch, or opaque value:

```elixir
def run(%{path: path}, _context) do
  {:ok, Jido.Action.Output.raw(File.read!(path), meta: %{path: path})}
end
```

An output envelope makes the non-map result intentional. It bypasses the normal
map output schema.

## Extras

Use a three-element tuple when a direct caller must receive data that is not
part of the action result:

```elixir
{:ok, %{email: "ada@example.com"}, %{cache: :hit}}
```

`Jido.Exec` preserves extras for an action or instruction call. A Flow node
uses only the action output or error. It discards node extras.

## Effects And Context

An action can be pure or effectful. It can use HTTP, a database, the file
system, or another service when the operation needs that effect.

Pass request-specific capabilities and data in the context:

```elixir
{:ok, result} =
  Jido.Exec.run(
    MyApp.Actions.NormalizeEmail,
    %{email: "ADA"},
    %{default_domain: "example.org", request_id: "req-1"}
  )
```

Do not place retry, timeout, fallback, persistence, or scheduling policy in the
action. The caller or a higher runtime layer owns that policy.

## Direct Calls And Jido.Exec

Use `Jido.Exec.run/3` for the complete public execution sequence:

```elixir
{:ok, %{email: "ada@example.org"}} =
  Jido.Exec.run(
    MyApp.Actions.NormalizeEmail,
    %{email: "ADA"},
    %{default_domain: "example.org"}
  )
```

Call `validate_params/1`, `run/2`, and `validate_output/1` directly when you
need explicit control over each boundary. A direct `run/2` call does not add
error normalization, output checks, process isolation, retries, or timeouts.
