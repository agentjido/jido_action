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

## Flow Tests

Run a Flow through `Jido.Exec` to test the same validation and execution path
that application code uses.

```elixir
defmodule MyApp.Flows.RouteShipmentTest do
  use ExUnit.Case, async: true

  alias MyApp.Flows.RouteShipment

  test "selects priority shipping" do
    assert {:ok, %{carrier: "priority"}} =
             Jido.Exec.run(RouteShipment, %{
               order_id: "ord-123",
               tier: :priority,
               item_count: 2
             })
  end

  test "uses standard shipping when no option matches" do
    assert {:ok, %{carrier: "standard"}} =
             Jido.Exec.run(RouteShipment, %{
               order_id: "ord-123",
               tier: :standard,
               item_count: 2
             })
  end
end
```

For each Choice, test these paths when they apply:

- Each option can be selected.
- The first matching option wins when more than one condition is true.
- The fallback runs when no option matches.
- Invalid condition operands return the expected error metadata.

## Step-wise Flow Tests

Use the step-wise API when node readiness or wave boundaries are part of the
contract.

```elixir
test "exposes each dependency wave" do
  assert {:ok, execution} =
           Jido.Exec.start(MyApp.Flows.BuildReport, %{account_id: "acct-123"})

  assert Jido.Exec.status(execution) == :running
  assert Jido.Exec.ready(execution) == ["load_account", "load_orders"]

  assert {:ok, node_results, execution} = Jido.Exec.wave(execution)
  assert Enum.map(node_results, & &1.status) == [:ok, :ok]
  assert Jido.Exec.ready(execution) == ["build_summary"]

  assert {:ok, execution} = Jido.Exec.continue(execution)
  assert Jido.Exec.status(execution) == :succeeded
  assert {:ok, _report} = Jido.Exec.result(execution)
end
```

Test failed nodes as state transitions. A failed node returns an `:ok` tuple
with a `Jido.Exec.NodeResult` that has `status: :error`. After all independent
work settles, `result/1` returns the Flow error.

When parallel timing is not the behavior under test, leave `async: false` on
the Flow execution. This keeps the test deterministic.
