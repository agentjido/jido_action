# Testing

Test each layer at its own boundary: Action logic directly, the Action
contract through `Jido.Exec`, Flow definitions without running them, and Flow
behavior through `Jido.Exec`.

## A Complete Test Module

```elixir
defmodule MyApp.Actions.Add do
  use Jido.Action,
    name: "add",
    schema: Zoi.object(%{left: Zoi.integer(), right: Zoi.integer()}),
    output_schema: Zoi.object(%{sum: Zoi.integer()})

  @impl true
  def run(%{left: left, right: right}, _context), do: {:ok, %{sum: left + right}}
end

defmodule MyApp.Flows.AddAndDouble do
  use Jido.Flow,
    name: "add_and_double",
    schema: Zoi.object(%{left: Zoi.integer(), right: Zoi.integer()})

  flow do
    step "add",
      action: MyApp.Actions.Add,
      params: %{left: input(:left), right: input(:right)}

    step "double",
      action: MyApp.Actions.Add,
      params: %{left: result("add", :sum), right: result("add", :sum)}

    output result("double")
  end
end

defmodule MyApp.Actions.AddTest do
  use ExUnit.Case, async: true

  alias MyApp.Actions.Add

  test "run/2 adds validated params" do
    {:ok, params} = Add.validate_params(%{left: 1, right: 2})
    assert {:ok, %{sum: 3}} = Add.run(params, %{})
  end

  test "Exec rejects invalid input before run/2" do
    assert {:error, %Jido.Action.Error.InvalidInputError{} = error} =
             Jido.Exec.run(Add, %{left: "1", right: 2})

    assert [%{path: [:left]}] = error.details.errors
  end

  test "the Flow definition is valid without running it" do
    flow = MyApp.Flows.AddAndDouble.flow()

    assert {:ok, _flow} = Jido.Flow.validate(flow)
    assert {:ok, %{"double" => %{references: ["add"]}}} = Jido.Flow.dependencies(flow)
    assert {:ok, %Runic.Workflow{}} = Jido.Exec.compile(flow)
  end

  test "the Flow returns its output" do
    assert {:ok, %{sum: 6}} = Jido.Exec.run(MyApp.Flows.AddAndDouble, %{left: 1, right: 2})
  end
end
```

## Test Actions

Call `validate_params/1`, `run/2`, and `validate_output/1` directly for the
business rule. These calls are fast and need no processes. A direct `run/2`
call skips validation, so validate params first when the callback relies on
schema defaults.

Then add a `Jido.Exec.run/4` test for the contract: invalid input is
rejected, output is validated, and failures become structured errors. Assert
on the error struct and its `details`, not on message text. See
[Errors](errors.md).

## Test Flow Definitions

Flow definition checks never run Action work:

- `Jido.Flow.new/1` and `Jido.Flow.validate/1` check structure, references,
  and cycles.
- `Jido.Flow.dependencies/1` and `Jido.Flow.explain/1` show the graph.
- `Jido.Exec.compile/2` also checks every Action and child Flow target.

For stored Flows, test a Codec round trip and the errors you expect for
unknown identifiers:

```elixir
assert {:ok, document, registry} = Jido.Flow.Codec.encode(flow)
assert {:ok, restored} = Jido.Flow.Codec.decode(document, registry)
assert Jido.Flow.to_map(restored) == Jido.Flow.to_map(flow)
```

## Test Flow Behavior

Run the Flow through `Jido.Exec.run/4` and assert the complete result,
including effects:

```elixir
assert {:ok, %{status: :approved}, [{:send_confirmation, "order-42"}]} =
         Jido.Exec.run(MyApp.Flows.ApproveOrder, %{order_id: "order-42"})
```

For Choice, Map, Reduce, Iterate, nested Flows, and Dispatch, assert the
public result, the effect order, and the error details for failures. To prove
that an Action ran, or did not run, have it send a message to the test
process and use `assert_received` or `refute_received`.

## Keep Tests Deterministic

- Do not use `Process.sleep/1` to wait for work. Use messages, monitors, or
  the managed `on_complete:` callback.
- Results and effects keep canonical order under any `max_concurrency`.
  Assert that order. Record execution order separately when it matters.
- Runic logs a warning for each failed runnable. Use
  `@moduletag capture_log: true` or `ExUnit.CaptureLog.capture_log/1` in
  tests that expect failures.
- Use unique telemetry handler IDs and detach them in `on_exit/1`.

## Test Managed Execution

Start a Runner per test with a unique name, and give each execution a unique
ID:

```elixir
setup do
  runner = :"runner_#{System.unique_integer([:positive])}"
  start_supervised!({Runic.Runner, name: runner})
  %{runner: runner}
end

test "a managed Flow completes", %{runner: runner} do
  parent = self()

  {:ok, _pid} =
    Jido.Exec.start(runner, "add-1", MyApp.Flows.AddAndDouble, %{left: 1, right: 2}, %{},
      on_complete: fn id, _workflow -> send(parent, {:done, id}) end
    )

  assert_receive {:done, "add-1"}
  assert {:ok, workflow} = Runic.Runner.get_workflow(runner, "add-1")
  assert {:ok, %{sum: 6}} = Jido.Exec.result(workflow)
end
```

## Test Flow Results

```elixir
assert {:ok, expected} = Jido.Exec.run(MyApp.Flows.BuildReport, input, context)
```

For Choice, Map, Reduce, Iterate, nested Flow, and Dispatch, assert the public
result, effect order, and relevant error details. Use messages or counters to
prove that failed or recovered work does not run twice.

## Test Durable Resume

Run durable tests through a real `Runic.Runner` and Store:

1. start the Flow with `Jido.Exec.start/6`;
2. block at a known Action;
3. checkpoint and stop the Worker;
4. call `Jido.Exec.resume/4` with the same context and options;
5. assert that completed Actions did not run again;
6. assert the result through `Jido.Exec.result/1` on the final workflow.

Use a stable execution ID. Keep process-local values out of durable params,
context, and outputs.

## Keep Concurrent Tests Deterministic

Use unique Runner names and execution IDs. Coordinate Actions with messages or
barriers instead of sleeps. When you test parallel work, compare ordered public
results and record the actual execution set separately.

## Property And System Suites

The repository separates larger checks:

```text
mix test.authoring
mix test.property
mix test.system
mix test.load
```

The default `mix test` suite excludes these tagged groups. Run all groups when
you change Flow compilation or Exec behavior.
