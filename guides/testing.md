# Testing

Test actions directly at the action boundary.

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

## Error Tests

Prefer asserting error structs and important message fragments.

```elixir
assert {:error, %Jido.Action.Error.InvalidInputError{}} =
         Add.validate_params(%{left: "1", right: 2})
```

Avoid log-only assertions unless log output is part of the contract.
