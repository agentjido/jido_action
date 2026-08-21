# Testing

Test action logic directly. Add boundary tests through `Jido.Exec` when you
need proof of validation, error normalization, output checks, or Flow
composition.

## Direct Unit Tests

Use direct calls when validating pure action logic.

```elixir
defmodule MyApp.Actions.AddTest do
  use ExUnit.Case, async: true

  alias MyApp.Actions.Add

  test "adds numbers" do
    assert {:ok, %{result: 3}} = Add.run(%{left: 1, right: 2}, %{})
  end
end
```

## Validation Tests

Test schema success and failure separately.

```elixir
test "validates params" do
  assert {:ok, %{left: 1, right: 2}} =
           Add.validate_params(%{left: 1, right: 2})

  assert {:error, %Jido.Action.Error.InvalidInputError{}} =
           Add.validate_params(%{left: "1", right: 2})
end
```

Do the same for `validate_output/1` when the action declares `output_schema`.

## Execution Boundary Tests

Use `Jido.Exec` to test the complete public action path:

```elixir
test "validates and executes the action" do
  assert {:ok, %{result: 3}} =
           Jido.Exec.run(Add, %{left: 1, right: 2}, %{})

  assert {:error, %Jido.Action.Error.InvalidInputError{}} =
           Jido.Exec.run(Add, %{left: "1", right: 2}, %{})
end
```

This test covers input validation, `run/2`, output validation, and public result
normalization.

## Instruction Tests

Use `Jido.Instruction` tests when action calls need to be represented as data.

```elixir
test "captures an action call" do
  assert {:ok, instruction} =
           Jido.Instruction.new(action: Add, params: %{left: 1, right: 2})

  assert instruction.action == Add
  assert instruction.params == %{left: 1, right: 2}
end
```

Add an execution assertion when call-site merges are part of the contract:

```elixir
assert {:ok, %{result: 5}} =
         Jido.Exec.run(instruction, %{left: 3}, %{request_id: "req-1"})
```

## Flow Tests

Test a Flow module through `Jido.Exec`. Also inspect its canonical dependency
map when graph structure is important.

```elixir
test "runs and explains the math flow" do
  assert {:ok, %{value: 8}} =
           Jido.Exec.run(MyApp.Flows.DoubleAfterIncrement, %{value: 3}, %{})

  assert {:ok, %{"add_one" => [], "double" => ["add_one"]}} =
           MyApp.Flows.DoubleAfterIncrement.dependencies()
end
```

When an application supports more than one Flow authoring language, compare
`Jido.Flow.to_map/1` results. This check proves that all language adapters lower
to the same canonical semantics.

## Error Tests

Prefer asserting error structs and important message fragments.

```elixir
assert {:error, %Jido.Action.Error.InvalidInputError{}} =
         Add.validate_params(%{left: "1", right: 2})
```

Avoid log-only assertions unless log output is part of the contract.

For telemetry tests, attach handlers to `[:jido, :exec, :run, :stop]` or
`[:jido, :flow, :node, :stop]`, and remove the handlers when each test ends.
