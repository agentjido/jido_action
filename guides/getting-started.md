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

## Run With Policy

```elixir
{:ok, %{result: 3}} =
  Jido.Exec.run(
    MyApp.Actions.Add,
    %{left: 1, right: 2},
    %{},
    timeout: 1_000,
    max_retries: 0
  )
```

`Jido.Exec` validates input before calling `run/2`, validates output after success, and normalizes exits, throws, and exceptions into action errors.

## Run Asynchronously

```elixir
ref = Jido.Exec.run_async(MyApp.Actions.Add, %{left: 1, right: 2}, %{})
{:ok, %{result: 3}} = Jido.Exec.await(ref, 5_000)
```

Use `Jido.Exec.cancel/1` when the result is no longer needed.

