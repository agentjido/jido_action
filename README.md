# Jido Action

`jido_action` defines validated leaf actions and composes them into Runic-backed flows.

V3 keeps the action boundary small while adding a stateful composition layer:

- `Jido.Action` defines a named action with Zoi input and output schemas.
- `Jido.Instruction` captures one requested action call as data.
- `Jido.Flow` composes leaf actions and native Runic components.
- `Jido.Exec` executes `Jido.Flow` and raw `Runic.Workflow` values. Retry, timeout, fallback, async, durable execution, and stepping use Runic policy.

Actions are leaves: `run/2` computes one action result; `Jido.Flow` composes actions; `Jido.Exec` executes the composition.

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

## Validate And Run An Action

```elixir
{:ok, params} = MyApp.Actions.GreetUser.validate_params(%{name: "Ada", excited?: true})
{:ok, result} = MyApp.Actions.GreetUser.run(params, %{request_id: "req-123"})
{:ok, result} = MyApp.Actions.GreetUser.validate_output(result)
```

`run/2` must return one of:

- `{:ok, result}`
- `{:ok, result, extra}`
- `{:error, reason}`
- `{:error, reason, extra}`

Three-tuple returns are consumed by flow steps when an action is used inside a flow.

## Capture A Call Frame

Use `Jido.Instruction` when the intent to run an action needs to be passed,
logged, queued, or enriched before execution.

```elixir
instruction =
  Jido.Instruction.new!(
    action: MyApp.Actions.GreetUser,
    params: %{name: "Ada"},
    context: %{request_id: "req-123"}
  )
```

An instruction is one action call frame. It is not a workflow, program, or runtime.

## Compose A Flow

Use `Jido.Flow` when multiple leaf actions need to run as a stateful composition.
Each action step wraps one `Jido.Instruction` and receives either the initial
runtime input or the upstream step result.

```elixir
flow =
  Jido.Flow.new(:greeting)
  |> Jido.Flow.step(:greet, MyApp.Actions.GreetUser)
  |> Jido.Flow.step(:decorate, MyApp.Actions.DecorateGreeting, after: :greet)

{:ok, result} = Jido.Exec.run(flow, %{name: "Ada"})

[%{message: message}] = Runic.Workflow.raw_productions(result.workflow, :decorate)
```

Fan-in dependencies use Runic joins. A downstream action receives the joined
values as `%{input: values}` unless it has static params that satisfy its schema.

Use `Jido.Flow.component/4` for native Runic components such as accumulators and
state machines:

```elixir
counter = Runic.accumulator(0, fn value, state -> state + value end, name: :counter)

flow =
  Jido.Flow.new(:counter)
  |> Jido.Flow.component(:counter, counter)

{:ok, result} = Jido.Exec.run(flow, 2)
{:ok, result} = result.workflow |> Jido.Flow.from_workflow() |> Jido.Exec.run(3)
```

Arbitrary cyclic graph edges are not the first Jido API. Model loops through
runtime cycles, repeated `Jido.Exec.resume/3` calls, and Runic stateful
components. Use `:max_cycles` to bound reactive execution.

## Runtime Policy

Use Runic scheduler policies on flows, workflows, or runtime calls:

```elixir
flow =
  Jido.Flow.new(:greeting)
  |> Jido.Flow.step(:greet, MyApp.Actions.GreetUser)
  |> Jido.Flow.policy(:greet, %{max_retries: 1, backoff: :none, timeout_ms: 1_000})
```

## Docs

Start with:

- [Getting Started](guides/getting-started.md)
- [Actions](guides/actions-guide.md)
- [Schemas & Validation](guides/schemas-validation.md)
- [Flows & Runtime](guides/flows-runtime.md)
- [Error Handling](guides/error-handling.md)
