# Actions

An Action is a leaf unit of work. It is a module that declares metadata and
schemas, then implements one `run/2` callback. Actions do not contain a graph
or a runtime policy.

## Define An Action

```elixir
defmodule MyApp.Actions.NormalizeEmail do
  use Jido.Action,
    name: "normalize_email",
    description: "Normalizes one email address",
    schema: Zoi.object(%{email: Zoi.string()}),
    output_schema: Zoi.object(%{email: Zoi.string()})

  @impl true
  def run(%{email: email}, _context) do
    {:ok, %{email: String.downcase(String.trim(email))}}
  end
end
```

The `:name` option is required. `:description`, `:schema`, and
`:output_schema` are optional. Schemas are static module data. See
[Schemas and Validation](schemas-validation.md) for schema behavior.

## The Callback

`run/2` receives a parameter map and a context map:

```elixir
@impl true
def run(params, context) do
  # params contains Action input.
  # context contains caller-owned execution data.
  {:ok, %{params: params, trace_id: Map.get(context, :trace_id)}}
end
```

Keep the callback focused on one operation. A callback can perform an external
side effect, but the Action does not decide whether the caller should retry,
wait, cancel, or persist that work.

## Valid Return Shapes

An Action can return a normal map result:

```elixir
{:ok, %{status: :accepted}}
{:error, :not_found}
```

It can also return an extra value for a direct caller:

```elixir
{:ok, %{status: :accepted}, %{event: :created}}
{:error, :rejected, %{reason_code: "LIMIT"}}
```

For a successful raw, stream, batch, or opaque value, return an explicit
`Jido.Action.Output` envelope:

```elixir
{:ok, Jido.Action.Output.raw(binary_data)}
```

`Jido.Exec` validates these shapes and normalizes failures. When an Action is a
Flow node, Flow execution uses the output or error reason and discards Action
extras.

## Schemas And Validation

An Action exposes `validate_params/1` and `validate_output/1`:

```elixir
{:ok, params} = MyApp.Actions.NormalizeEmail.validate_params(%{email: "A@EXAMPLE.COM"})
{:ok, output} = MyApp.Actions.NormalizeEmail.validate_output(%{email: "a@example.com"})
```

These functions return `{:error, %Jido.Action.Error.InvalidInputError{}}` when
validation fails. Input and output schemas must describe map-shaped Action
data. Object validation preserves unknown keys for caller-owned metadata.

## Direct Run And Jido.Exec

Call `run/2` directly when you have already validated the data and want only
the callback:

```elixir
{:ok, params} = MyApp.Actions.NormalizeEmail.validate_params(%{email: "A@EXAMPLE.COM"})
{:ok, output} = MyApp.Actions.NormalizeEmail.run(params, %{})
{:ok, output} = MyApp.Actions.NormalizeEmail.validate_output(output)
```

Use `Jido.Exec.run/4` at the public execution boundary:

```elixir
{:ok, output} = Jido.Exec.run(MyApp.Actions.NormalizeEmail, %{email: "A@EXAMPLE.COM"}, %{})
```

`Jido.Exec` performs input validation, invokes the callback, validates normal
output, and normalizes exceptions, unsupported return values, and error
reasons. An Action and an Instruction with an Action target accept common
`jido:` instance routing. They do not accept Flow policy options.

## Boundary Of An Action

The Action owns:

- its operation and side-effect code,
- input and output schemas, and
- the error reasons it returns.

The caller or execution layer owns retries, timeouts, scheduling, concurrency,
fallbacks, cancellation, and persistence. Use a Flow when several Actions must
be represented as one data artifact.
