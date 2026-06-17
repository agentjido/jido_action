# Testing

Test actions at two levels: direct `run/2` unit tests and `Jido.Exec` integration tests.

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

## Exec Tests

Use `Jido.Exec` when testing timeout, retry, output validation, context propagation, async behavior, or crash normalization.

```elixir
test "runs through Exec" do
  assert {:ok, %{result: 3}} =
           Jido.Exec.run(Add, %{left: 1, right: 2}, %{}, timeout: 1_000)
end
```

## Async Tests

Assert cleanup behavior directly instead of relying on timing guesses.

```elixir
test "awaits async action" do
  ref = Jido.Exec.run_async(Add, %{left: 1, right: 2}, %{})
  assert {:ok, %{result: 3}} = Jido.Exec.await(ref, 5_000)
end
```

For cancellation:

```elixir
ref = Jido.Exec.run_async(SlowAction, %{}, %{}, timeout: 10_000)
assert :ok = Jido.Exec.cancel(ref)
```

## Error Tests

Prefer asserting error structs and important message fragments.

```elixir
assert {:error, %Jido.Action.Error.TimeoutError{}} =
         Jido.Exec.run(SlowAction, %{}, %{}, timeout: 10)
```

Avoid log-only assertions unless log output is part of the contract.

