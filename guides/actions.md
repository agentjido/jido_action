# Actions

An Action is one named and validated unit of work. It is the only executable
leaf in a Jido Flow.

## Define An Action

```elixir
defmodule MyApp.Actions.CreateGreeting do
  use Jido.Action,
    name: "create_greeting",
    description: "Creates one greeting",
    schema: Zoi.object(%{name: Zoi.string()}),
    output_schema: Zoi.object(%{message: Zoi.string()})

  @impl true
  def run(%{name: name}, context) do
    prefix = Map.get(context, :prefix, "Hello")
    {:ok, %{message: prefix <> ", " <> name <> "!"}}
  end
end
```

`use Jido.Action` generates these public functions:

- `name/0` and `description/0`;
- `schema/0` and `output_schema/0`;
- `validate_params/1` and `validate_output/1`; and
- the `Jido.Executable` descriptor used by `Jido.Exec`.

The module must implement `run/2`.

## Callback Results

An Action callback returns one of these shapes:

```elixir
{:ok, result}
{:ok, result, extras}
{:error, reason}
{:error, reason, extras}
{:continue, continuation_input, continuation_target}
```

A normal success result is a map. Use `Jido.Action.Output` when a successful
value is intentionally raw, streamed, batched, or opaque.

```elixir
{:ok, Jido.Action.Output.raw("complete")}
{:ok, Jido.Action.Output.batch([%{id: 1}, %{id: 2}])}
```

Direct Action and Action Instruction calls preserve `extras`. A Flow consumes
only the result or error reason from an Action node and discards node extras.

A continuation input is a map. Its target is an Action module, a Flow module,
or a runtime Flow value. Jido runs the target and uses its output as the
effective result of the current Action. See
[Action And Flow Continuations](continuations.md).

## Validation

A direct `run/2` call does not validate data. Validate both boundaries when you
call the callback directly.

```elixir
with {:ok, params} <- MyApp.Actions.CreateGreeting.validate_params(%{name: "Ada"}),
     {:ok, result} <- MyApp.Actions.CreateGreeting.run(params, %{prefix: "Hi"}),
     {:ok, result} <- MyApp.Actions.CreateGreeting.validate_output(result) do
  {:ok, result}
end
```

Use `Jido.Exec.run/4` for the normal application boundary.

```elixir
Jido.Exec.run(
  MyApp.Actions.CreateGreeting,
  %{name: "Ada"},
  %{prefix: "Hi"},
  timeout: 5_000
)
```

Exec validates input, calls the Action in an owned process, validates normal
output, and converts exceptions, throws, exits, and invalid return shapes to
structured errors. It does not retry the Action.

## Action Design Rules

- Keep one Action focused on one unit of work.
- Put external effects in the Action, not in a Flow expression.
- Treat context as caller-owned execution data.
- Return structured domain errors when the caller can act on them.
- Make effects idempotent when a higher-level runtime can repeat work.

See [Schemas And Validation](schemas-validation.md) and
[Execution Contract](execution.md) for the complete boundary.
