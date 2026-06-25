# Jido Action

`jido_action` defines validated leaf actions and action call frames.

This foundation keeps the action boundary small:

- `Jido.Action` defines a named action with Zoi input and output schemas.
- `Jido.Instruction` captures one requested action call as data.

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

Three-tuple returns let callers receive an extra value alongside the result or error.

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

## Docs

Start with:

- [Getting Started](guides/getting-started.md)
- [Actions](guides/actions-guide.md)
- [Schemas & Validation](guides/schemas-validation.md)
- [Error Handling](guides/error-handling.md)
