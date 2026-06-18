# Testing

Test actions at two levels: direct action tests and flow runtime tests.

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

## Flow Runtime Tests

Use `Jido.Exec` when testing Runic-backed flow composition and scheduler policy.

```elixir
test "runs through a flow" do
  flow = Jido.Flow.new(:math) |> Jido.Flow.step(:add, Add)
  assert {:ok, result} = Jido.Exec.run(flow, %{left: 1, right: 2})
  assert Jido.Exec.results(result).add == [%{result: 3}]
end
```

## Error Tests

Prefer asserting error structs and important message fragments.

```elixir
assert {:error, %Jido.Action.Error.InvalidInputError{}} =
         Add.validate_params(%{left: "1", right: 2})
```

Avoid log-only assertions unless log output is part of the contract.
