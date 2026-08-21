# Jido Action

`jido_action` provides validated actions and explicit composition for Elixir
applications.

The package has four main parts:

- `Jido.Action` defines one named operation.
- `Jido.Instruction` stores one requested action call as data.
- `Jido.Exec` validates and runs actions, instructions, and flows.
- `Jido.Flow` defines a graph of action calls with one declared return value.

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

Run the action through the public execution boundary:

```elixir
{:ok, %{greeting: "Hello, Ada!"}} =
  Jido.Exec.run(
    MyApp.Actions.GreetUser,
    %{name: "Ada", excited?: true},
    %{request_id: "req-123"}
  )
```

`Jido.Exec` validates the input, calls `run/2`, normalizes failures, and
validates the output.

## Capture A Call Frame

Use `Jido.Instruction` when one action call must be passed, stored, or changed
before execution.

```elixir
instruction =
  Jido.Instruction.new!(
    action: MyApp.Actions.GreetUser,
    params: %{name: "Ada"},
    context: %{request_id: "req-123"}
  )

{:ok, %{greeting: "Hello, Ada."}} = Jido.Exec.run(instruction)
```

An instruction is one action call frame. It is not a workflow or an execution
policy.

## Compose A Flow

Use `Jido.Flow` when several actions must form one static dependency graph.
All Flow authoring surfaces create the same canonical `%Jido.Flow{}` artifact.
Run that artifact through `Jido.Exec`.

## Guides

Start with these guides:

- [Getting Started](guides/getting-started.md)
- [Jido.Action](guides/actions-guide.md)
- [Jido.Instruction](guides/instructions.md)
- [Jido.Exec](guides/exec.md)
- [How Jido Flow Works](guides/jido-flow.md)
- [Flow Authoring Languages](guides/flow-authoring-languages.md)
