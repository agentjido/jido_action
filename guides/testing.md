# Testing

Test each boundary that your application relies on: Action behavior, data
validation, Flow structure, and Flow execution. Keep tests deterministic. Use
`async: true` only when the parallel scheduling contract is the behavior under
test.

## Test Actions

Call an Action directly for pure Action behavior.

```elixir
defmodule MyApp.Actions.AddTest do
  use ExUnit.Case, async: true

  alias MyApp.Actions.Add

  test "adds numbers" do
    assert {:ok, %{result: 3}} = Add.run(%{left: 1, right: 2}, %{})
  end
end
```

Test success, structured errors, effects, and important context handling. Do
not make a log line the only assertion for an Action result.

## Test Instructions

An Instruction is data for one Action call. Test construction and execution
merge behavior when the application passes Instructions between boundaries.

```elixir
test "captures an action call" do
  assert {:ok, instruction} =
           Jido.Instruction.new(action: MyApp.Actions.Add, params: %{left: 1, right: 2})

  assert instruction.action == MyApp.Actions.Add
  assert instruction.params == %{left: 1, right: 2}
end
```

Use `Jido.Exec.run/4` for the execution test of the normalized Instruction.

## Test Schemas And Validation

Test valid and invalid input separately. Test output validation when an Action
or Flow declares an output schema.

```elixir
test "rejects invalid action input" do
  assert {:error, %Jido.Action.Error.InvalidInputError{}} =
           MyApp.Actions.Add.validate_params(%{left: "1", right: 2})
end

test "accepts valid action input" do
  assert {:ok, %{left: 1, right: 2}} =
           MyApp.Actions.Add.validate_params(%{left: 1, right: 2})
end
```

Include defaults, optional keys, unknown key preservation, and output shape in
tests when those features are part of the contract.

## Test The Flow Graph

Test the canonical graph before testing runtime behavior. Assert node names,
dependencies, return shape, and semantic identity when these are important to
the application.

```elixir
test "declares the dependency graph" do
  flow = MyApp.Flows.BuildReport.flow()

  assert {:ok, dependencies} = Jido.Flow.dependencies(flow)
  assert dependencies["build_summary"] == ["load_account", "load_orders"]

  assert {:ok, explanation} = Jido.Flow.explain(flow)
  assert Enum.map(explanation.nodes, & &1.name) == [
           "load_account",
           "load_orders",
           "build_summary"
         ]
end
```

Test malformed Flow artifacts and invalid references as validation failures.

## Test Choices

For each Choice, test each option, the ordered first-match rule, and the
required fallback.

```elixir
test "routes priority work" do
  assert {:ok, %{route: :priority}} =
           Jido.Exec.run(MyApp.Flows.Route, %{tier: :priority}, %{})
end

test "routes to the fallback" do
  assert {:ok, %{route: :standard}} =
           Jido.Exec.run(MyApp.Flows.Route, %{tier: :other}, %{})
end
```

Also test short-circuit behavior with a later condition that would fail if Jido
evaluated it. A Choice fallback is routing logic, not recovery for a selected
target that fails.

## Test Map And Reduce

Test Map output order, both Map error modes, and the empty collection. Test
Reduce with a non-associative case so that source order is visible. Also test
an empty Reduce collection and the initial accumulator.

```elixir
test "maps and reduces in source order" do
  assert {:ok, %{mapped: %{results: results, errors: []}, total: %{total: 12}}} =
           Jido.Exec.run(MyApp.Flows.DoubleAndSum, %{values: [1, 2, 3]}, %{})

  assert Enum.map(results, & &1.index) == [0, 1, 2]
  assert Enum.map(results, & &1.output.value) == [2, 4, 6]
end
```

When `async: true` is important, assert the ordered records and the configured
concurrency boundary. Do not use task completion order as a result assertion.
See [Map and Reduce](flow-collections.livemd).

## Test Loops And State

Test the initial head condition, the first State update, normal completion,
and exhaustion at `max_iterations`. Assert the complete Loop result, including
`iterations`, `state`, and `output`.

```elixir
test "commits each loop state replacement" do
  assert {:ok, %{iterations: 3, state: %{count: 3}, output: %{count: 3}}} =
           Jido.Exec.run(MyApp.Flows.CountThree, %{}, %{})
end

test "can complete before the first body call" do
  assert {:ok, %{iterations: 0, state: %{count: 3}, output: nil}} =
           Jido.Exec.run(MyApp.Flows.CountUntil, %{start: 3, target: 3}, %{})
end
```

Test State schema failures without exposing rejected State values. If the Loop
body has effects, also test the repeat-risk and idempotency boundary. See
[Loops and State](flow-loops-state.livemd).

## Test Nested Flows

Test the child Flow directly for its own graph and behavior. Test the parent
for input mapping, child output mapping, and the atomic parent node boundary.

```elixir
test "reports a nested Flow as one parent node" do
  assert {:ok, execution} =
           Jido.Exec.start(MyApp.Flows.Parent, %{value: 4}, %{})

  assert ["child"] = Jido.Exec.ready(execution)
  assert {:ok, %Jido.Exec.NodeResult{node: "child", status: :ok}, execution} =
           Jido.Exec.step(execution, "child")

  assert Jido.Exec.status(execution) == :succeeded
end
```

The parent does not expose child nodes. Parent `async` and
`max_concurrency` options do not propagate to a nested Flow.

## Test Step-wise Execution

Use `start/4` when readiness and manual transitions are part of the contract.
Assert the latest execution after every transition.

```elixir
test "steps through dependency waves" do
  assert {:ok, execution} = Jido.Exec.start(MyApp.Flows.BuildReport, %{account_id: "acct-1"})
  assert Jido.Exec.status(execution) == :running
  assert Jido.Exec.ready(execution) == ["load_account", "load_orders"]

  assert {:ok, %Jido.Exec.NodeResult{node: "load_account", status: :ok}, execution} =
           Jido.Exec.step(execution, "load_account")

  assert Jido.Exec.ready(execution) == ["load_orders"]

  assert {:ok, %Jido.Exec.NodeResult{node: "load_orders", status: :ok}, execution} =
           Jido.Exec.step(execution)

  assert Jido.Exec.ready(execution) == ["build_summary"]
  assert {:ok, %Jido.Exec.NodeResult{node: "build_summary", status: :ok}, execution} =
           Jido.Exec.step(execution)

  assert Jido.Exec.status(execution) == :succeeded
  assert {:ok, %{account_id: "acct-1", order_count: 1}} = Jido.Exec.result(execution)
end
```

Test that a non-ready node returns `{:error, error}` and leaves the old
execution unchanged. Test that a terminal execution rejects further steps.

## Test Waves

`wave/1` executes only the nodes that were ready at the start of the call.
This makes dependency boundaries easy to assert without time-based checks.

```elixir
test "executes one ready wave" do
  assert {:ok, execution} = Jido.Exec.start(MyApp.Flows.BuildReport, %{account_id: "acct-wave"})
  assert {:ok, results, execution} = Jido.Exec.wave(execution)

  assert Enum.map(results, & &1.node) == ["load_account", "load_orders"]
  assert Enum.all?(results, &(&1.status == :ok))
  assert Jido.Exec.ready(execution) == ["build_summary"]
end
```

## Test Failures And Independent Work

A node failure is an applied transition. The step result is `{:ok, node_result,
latest_execution}`, with `node_result.status == :error`. Dependent nodes are
skipped, while independent nodes can remain ready.

```elixir
test "keeps independent work ready after a failure" do
  assert {:ok, execution} = Jido.Exec.start(MyApp.Flows.FailureFlow)
  assert {:ok, %Jido.Exec.NodeResult{status: :error}, execution} =
           Jido.Exec.step(execution, "fail")

  assert Jido.Exec.ready(execution) == ["record_audit"]
  assert {:ok, %Jido.Exec.NodeResult{status: :ok}, execution} =
           Jido.Exec.step(execution, "record_audit")

  assert Jido.Exec.status(execution) == :failed
  assert {:error, _error} = Jido.Exec.result(execution)
end
```

Use `capture_log: true` when the failure path emits expected error logs.
Assert error types and important details, not full log formatting.

## Test Parallel Options

The Flow API supports only `async` and `max_concurrency`. Test option
validation directly, and use `async: true` to test that independent nodes can
be scheduled in the same wave.

```elixir
test "accepts the parallel execution options" do
  assert {:ok, execution} =
           Jido.Exec.start(
             MyApp.Flows.BuildReport,
             %{account_id: "acct-parallel"},
             %{},
             async: true,
             max_concurrency: 2
           )

  assert {:ok, results, _execution} = Jido.Exec.wave(execution)
  assert Enum.map(results, & &1.node) == ["load_account", "load_orders"]
end

test "rejects unsupported runtime policy" do
  assert {:error, %Jido.Action.Error.InvalidInputError{}} =
           Jido.Exec.start(MyApp.Flows.BuildReport, %{}, %{}, timeout: 100)
end
```

Do not assert elapsed time to prove parallelism. Scheduler load makes timing
tests flaky. Instead, assert the ready set, the wave result order, and the
stored option behavior. The current API does not provide retries, backoff,
timeouts, deadlines, cancellation, rewind, or persistence; test those policies
in the higher-level runtime that owns them.
