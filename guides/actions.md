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

The module must implement `run/2`. A missing implementation stops compilation.

`Jido.Action` declares the `run/2` callback and the optional input-preparation
hook. `Jido.Executable` declares the descriptor, `validate_params/1`, and
`validate_output/1` callbacks shared by Action and Flow modules. An Action
implements both behaviours. A Flow implements `Jido.Executable` and supplies
`flow/0` as its definition. Runtime contract checks remain in place for all
module targets, including modules that do not declare the behaviours.

## Migrate Earlier v3 Beta Actions

Earlier v3 beta versions supplied a default `run/2` that returned a runtime
configuration error. That implementation and its `defoverridable` entry are
removed. The generator now declares `run/2` without a body. The Elixir compiler
rejects an Action that does not implement it, including during runtime module
compilation and ordinary Mix builds.

Add an explicit `run/2` body to every Action, including schema-only fixtures.
Use the callback example above. Replace calls to the removed default through
`super/2` with application code. Generated inline Actions already supply their
own callback. Existing Action result, validation, and extra-value rules stay
the same.

## Use An Inline Step For Small Local Work

A Flow module can define a small Step body without a separate Action module:

```elixir
defmodule ActionGuide.Greeting do
  use Jido.Flow, name: "inline_greeting"

  flow do
    step "greet", name <- input(:name) do
      {:ok, %{message: "Hello, " <> name <> "!"}}
    end

    output result("greet")
  end
end
```

This form, added in `3.0.0-beta.5`, compiles the body to an ordinary Action. It does
not add inline methods to `use Jido.Action` or function/MFA executable targets.
The Action has empty field schemas, with the normal map input and output
boundary. Exec still owns validation, errors, timeouts, and telemetry.

The [portable inline form](inline-actions.md), available in `3.0.0-beta.6`,
also accepts explicit schemas, descriptions, and execution context in Flow or
a downstream host DSL. No schema is inferred from bindings.
Keep a named Action for custom lifecycle hooks or a public module API
independent of the host. Use
`ActionGuide.Greeting.step_action("greet")` when you only need to reuse the
compiled target. See [Build Your First Flow](build-your-first-flow.livemd) for
the complete inline example and named-Action extraction.

## Callback Results

An Action callback returns one of five shapes:

```elixir
{:ok, result}
{:ok, result, extras}
{:error, reason}
{:error, reason, extras}
{:continue, input, target}
```

A normal success result is a map. Use `Jido.Action.Output` when a successful
value is intentionally raw, streamed, batched, or opaque.

```elixir
{:ok, Jido.Action.Output.raw("complete")}
{:ok, Jido.Action.Output.batch([%{id: 1}, %{id: 2}])}
```

Direct Action and Action Instruction calls preserve `extras`. A Flow consumes
only the result or error reason from an Action node and discards node extras.

`{:continue, input, target}` tells `Jido.Exec` what to run next. The current
Action does not return a domain result. `Jido.Exec` runs `target` with `input`
and the same context. The target can be an Action or a Flow. The final target
owns output validation and the final result.

Exec permits this result from a root Action and from the expander of a
`Jido.Flow.Dispatch` component at the end of a Flow. Other Flow positions reject
it. See [Continue to Another Executable](continuations.md).

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

### Prepare Raw Input

Implement `on_before_validate_params/1` only when raw input must change before
Zoi can parse it:

```elixir
@impl true
def on_before_validate_params(%{"enabled" => value} = params)
    when value in ["true", "false"] do
  prepared =
    params
    |> Map.delete("enabled")
    |> Map.put(:enabled, value == "true")

  {:ok, prepared}
end
```

`validate_params/1` and `Jido.Exec.run/4` both run this callback before the
input schema. The callback must return `{:ok, map}` or `{:error, reason}`.

Prefer Zoi coercion, defaults, enums, and refinements when they can express the
required rule. Keep authentication, authorization, secret lookup, I/O, retry,
and compensation out of this callback.

## Action Design Rules

- Keep one Action focused on one unit of work.
- Put external effects in the Action, not in a Flow expression.
- Treat context as caller-owned execution data.
- Return structured domain errors when the caller can act on them.
- Make effects idempotent when a higher-level runtime can repeat work.

See [Schemas And Validation](schemas-validation.md) and
[Execution Contract](execution.md) for the complete boundary.
