# Jido Action

`jido_action` defines validated leaf actions and runs them with hardened execution policy.

V3 keeps this package focused on one boundary:

- `Jido.Action` defines a named action with Zoi input and output schemas.
- `Jido.Instruction` captures one requested action call as data.
- `Jido.Exec` validates params, runs one action, applies timeout and retry policy, validates output, and normalizes crashes.
- Async execution, cancellation, telemetry, context propagation, and instance-scoped supervisors remain in `Jido.Exec`.

Higher-level orchestration and adapters should build on this leaf-action boundary instead of living inside this package.

## Install

```elixir
def deps do
  [
    {:jido_action, "~> 3.0"}
  ]
end
```

## Define An Action

```elixir
defmodule MyApp.Actions.GreetUser do
  use Jido.Action,
    name: "greet_user",
    description: "Builds a greeting for a user",
    schema:
      Zoi.object(%{
        name: Zoi.string() |> Zoi.min(1),
        excited?: Zoi.boolean() |> Zoi.default(false)
      }),
    output_schema:
      Zoi.object(%{
        greeting: Zoi.string()
      })

  @impl true
  def run(%{name: name, excited?: excited?}, _context) do
    suffix = if excited?, do: "!", else: "."
    {:ok, %{greeting: "Hello, #{name}#{suffix}"}}
  end
end
```

Public action functions:

- `name/0`
- `description/0`
- `schema/0`
- `output_schema/0`
- `validate_params/1`
- `validate_output/1`
- `run/2`

## Run An Action

```elixir
{:ok, result} =
  Jido.Exec.run(
    MyApp.Actions.GreetUser,
    %{name: "Ada", excited?: true},
    %{request_id: "req-123"},
    timeout: 1_000,
    max_retries: 1,
    backoff: 100
  )
```

`run/2` must return one of:

- `{:ok, result}`
- `{:ok, result, extra}`
- `{:error, reason}`
- `{:error, reason, extra}`

Three-tuple returns preserve the third value after output validation.

## Capture A Call Frame

Use `Jido.Instruction` when the intent to run an action needs to be passed,
logged, queued, or enriched before execution.

```elixir
instruction =
  Jido.Instruction.new!(
    action: MyApp.Actions.GreetUser,
    params: %{name: "Ada"},
    context: %{request_id: "req-123"},
    opts: [timeout: 1_000]
  )

{:ok, result} = Jido.Exec.run(instruction)
```

An instruction is one action call frame. It is not a workflow or program.

## Async Execution

```elixir
ref = Jido.Exec.run_async(MyApp.Actions.GreetUser, %{name: "Ada"}, %{})

case Jido.Exec.await(ref, 5_000) do
  {:ok, result} -> result
  {:error, reason} -> {:failed, reason}
end
```

Cancel work that is no longer needed:

```elixir
:ok = Jido.Exec.cancel(ref)
```

## Runtime Policy

`Jido.Exec.run/4` supports:

- `:timeout` - max action runtime in milliseconds, `0` disables supervised timeout wrapping.
- `:max_retries` - number of retry attempts after the first failure.
- `:backoff` - initial retry delay in milliseconds, doubled per retry and capped.
- `:log_level` - execution log level.
- `:jido` - instance namespace for isolated supervisors.
- `:context_propagators` - modules that capture and reattach process-local runtime context.
- `:context_propagator_failure_mode` - `:warn` or `:strict`.

Defaults can be configured with:

```elixir
config :jido_action,
  default_timeout: 30_000,
  default_max_retries: 1,
  default_backoff: 250
```

## Docs

Start with:

- [Getting Started](guides/getting-started.md)
- [Actions](guides/actions-guide.md)
- [Schemas & Validation](guides/schemas-validation.md)
- [Execution Engine](guides/execution-engine.md)
- [Error Handling](guides/error-handling.md)
