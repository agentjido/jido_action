# Getting Started

This guide defines one action and runs it through `Jido.Exec`.

## Add The Dependency

```elixir
def deps do
  [
    {:jido_action, "~> 3.0"}
  ]
end
```

## Create An Action

```elixir
defmodule MyApp.Actions.Add do
  use Jido.Action,
    name: "add",
    description: "Adds two integers",
    schema:
      Zoi.object(%{
        left: Zoi.integer(),
        right: Zoi.integer()
      }),
    output_schema:
      Zoi.object(%{
        result: Zoi.integer()
      })

  @impl true
  def run(%{left: left, right: right}, _context) do
    {:ok, %{result: left + right}}
  end
end
```

`use Jido.Action` creates metadata and validation functions. Your module must
implement `run/2`.

## Run The Action

```elixir
{:ok, %{result: 3}} =
  Jido.Exec.run(MyApp.Actions.Add, %{left: 1, right: 2}, %{})
```

`Jido.Exec` performs this sequence:

1. It checks the action contract.
2. It validates the input with `validate_params/1`.
3. It calls `run/2` with the validated input and the context.
4. It normalizes failures.
5. It validates a successful output with `validate_output/1`.

Invalid input does not call the action:

```elixir
{:error, %Jido.Action.Error.InvalidInputError{}} =
  Jido.Exec.run(MyApp.Actions.Add, %{left: "1", right: 2}, %{})
```

## Validate Without Execution

Call the generated validators when you only need boundary validation:

```elixir
{:ok, params} = MyApp.Actions.Add.validate_params(%{left: 1, right: 2})
{:ok, output} = MyApp.Actions.Add.validate_output(%{result: 3})
```

Direct `run/2` calls are also valid. A direct call does not apply the complete
`Jido.Exec` validation and error-normalization sequence.

## Continue

Read these guides next:

- [Jido.Action](actions-guide.md) describes the action contract.
- [Jido.Instruction](instructions.md) describes action calls as data.
- [Jido.Exec](exec.md) describes the execution boundary.
- [How Jido Flow Works](jido-flow.md) describes action composition.
