# Actions

An Action is a module that does one named, validated unit of work. It
declares schemas for its input and output and implements `run/2`. Every Flow
component that does work calls an Action.

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

Use `to_json/0` when a tool registry, an API, or a language model needs to
describe the Action.

```elixir
MyApp.Actions.CreateGreeting.to_json()
#=> %{
#=>   "kind" => "action",
#=>   "name" => "create_greeting",
#=>   "description" => "Creates one greeting",
#=>   "input_schema" => %{"type" => "object", ...},
#=>   "output_schema" => %{"type" => "object", ...}
#=> }
```

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

The body compiles to an ordinary Action. Its schemas default to empty. Use
the Step's `inline:` settings for explicit schemas, a description, or the
execution context. Schemas are not inferred from bindings. See
[Inline Steps](inline-actions.md).

The separate public `Jido.Action.Inline` API lets a downstream package provide
inline Actions in its own compile-time DSL.
Keep a named Action for custom lifecycle hooks or a public module API
independent of the host. Use
`ActionGuide.Greeting.step_action("greet")` when you only need to reuse the
compiled target. See [Build Your First Flow](build-your-first-flow.livemd) for
the complete inline example and named-Action extraction.

## Callback Results

An Action callback returns one of four shapes:

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

Return `{:ok, result, effects}` to request deferred effects, such as an email
to send after the work succeeds. `effects` must be a proper list. Exec returns
the list with the result and never performs it. Error results discard their
effects. See [Outputs And Effects](action-effects.livemd) for ordering and
examples.

A Dispatch expander, and only a Dispatch expander, can also return
`{:continue, input, target}` to select the next Action or Flow. Any other
Action that returns it fails with `reason: :unsupported_continuation`. See
[Dynamic Flows](dynamic-flows.md).

Exec turns raises, throws, exits, and unsupported return values into
structured errors. See [Errors](errors.md).

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
Action error only when it sets `details.retry: true`. The fourth argument sets
timeout, retry, and concurrency options. See
[Execution](execution.md#options).

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

def on_before_validate_params(params), do: {:ok, params}
```

Include a final clause that returns other input unchanged. Without it, any
other input raises `FunctionClauseError`, which Exec returns as an execution
error.

`validate_params/1` and `Jido.Exec.run/4` both run this callback before the
input schema. The callback must return `{:ok, params}` or `{:error, reason}`.

Prefer Zoi coercion, defaults, enums, and refinements when they can express the
required rule. Keep authentication, authorization, secret lookup, I/O, retry,
and compensation out of this callback.

## Action Design Rules

- Keep one Action focused on one unit of work.
- Put external effects in the Action, not in a Flow expression.
- Treat context as caller-owned execution data.
- Keep PIDs, references, and functions out of params and context when the
  Action runs under [managed execution](managed-execution.md).
- Return structured domain errors when the caller can act on them.
- Make effects idempotent when work can be retried with `max_attempts` or
  resumed after a crash.

See [Schemas And Validation](schemas-validation.md) and
[Execution](execution.md) for the complete boundary.
