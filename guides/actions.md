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
- `to_json/0` for a compile-time JSON-safe description;
- `validate_params/1` and `validate_output/1`.

The module must implement `run/2`. A missing implementation stops compilation.

`to_json/0` returns the Action name, description, input JSON Schema, and output
JSON Schema. It returns `nil` for an empty input or output schema. It raises
`ArgumentError` when Zoi cannot project a declared schema to JSON Schema. That
projection is descriptive. Use `validate_params/1` and `validate_output/1` for
the runtime contract.

`Jido.Action` declares `run/2`, `validate_params/1`, `validate_output/1`, and
the optional input-preparation hook. A Flow implements `Jido.Flow` and supplies
`flow/0` plus its validation callbacks. `Jido.Instruction` resolves these
behaviours to an execution kind. Runtime contract checks remain in place for
all resolved module targets.

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

This form compiles the body to an ordinary Action. It does not add inline
methods to `use Jido.Action` or function/MFA executable targets. Its field
schemas default to empty. Use Step `inline:` settings for explicit schemas,
descriptions, or execution context. No schema is inferred from bindings.
Exec owns the Jido adapter and result contract. Runic owns execution policy.

The separate public `Jido.Action.Inline` API lets a downstream package provide
inline Actions in its own compile-time DSL.
Keep a named Action for custom lifecycle hooks or a public module API
independent of the host. Use
`ActionGuide.Greeting.step_action("greet")` when you only need to reuse the
compiled target. See [Build Your First Flow](build-your-first-flow.livemd) for
the complete inline example and named-Action extraction.

## Callback Results

An Action callback returns one of four normal shapes:

```elixir
{:ok, result}
{:ok, result, effects}
{:error, reason}
{:error, reason, effects}
```

A normal success result is a map. Use `Jido.Action.Output` when a successful
value is intentionally raw, streamed, batched, or opaque.

```elixir
{:ok, Jido.Action.Output.raw("complete")}
{:ok, Jido.Action.Output.batch([%{id: 1}, %{id: 2}])}
```

Effects are optional for both maps and Output values. Return
`{:ok, result, requests}` with a proper list to request deferred effects.
An empty list returns the two-element success form. Direct Actions and Flows
preserve the requests. Exec does not dispatch them or consume stream output.
Non-list third success elements fail with `:invalid_effects`. Put metadata in
the result map or `Output.meta`. Error results discard the third element.
See the [effect rules](execution.md#results-and-errors).

A terminal Flow Dispatch expander can also return its special
`{:continue, input, target}` form. Root Actions and other Flow positions reject
that form. See [Dynamic Flows](dynamic-flows.md).

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

Exec runs input validation, the Action callback, output validation, and result
normalization through a Runic Runnable. Exceptions and invalid return shapes
become structured errors. Runic owns timeout and retry policy. Exec retries an
Action error only when it sets `details.retry: true`.

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
- Keep process-local values out of context when managed execution must persist
  and resume it.
- Return structured domain errors when the caller can act on them.
- Make effects idempotent when a higher-level runtime can repeat work.

See [Schemas And Validation](schemas-validation.md) and
[Execution Contract](execution.md) for the complete boundary.
