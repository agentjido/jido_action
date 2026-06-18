# Getting Started

This guide defines and runs one action.

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

## Validate Parameters

```elixir
{:ok, params} = MyApp.Actions.Add.validate_params(%{left: 1, right: 2})
{:error, error} = MyApp.Actions.Add.validate_params(%{left: "1", right: 2})
```

Validation returns `Jido.Action.Error.InvalidInputError` on failure.

## Run Directly

```elixir
{:ok, params} = MyApp.Actions.Add.validate_params(%{left: 1, right: 2})
{:ok, %{result: 3}} =
  MyApp.Actions.Add.run(params, %{})
```

Use `Jido.Flow` and `Jido.Exec` when you need Runic runtime policy:

```
flow = Jido.Flow.new(:math) |> Jido.Flow.step(:add, MyApp.Actions.Add)
{:ok, result} = Jido.Exec.run(flow, %{left: 1, right: 2})
```
