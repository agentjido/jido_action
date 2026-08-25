# Testing

Test each boundary that your application relies on: Action behavior, data
validation, Flow structure, and Flow execution. Keep tests deterministic. Use
`async: true` only when the parallel scheduling contract is the behavior under
test.

## Organize Tests By Boundary

Give each behavior one primary test owner:

1. Data tests cover Action, Flow, component, expression, and Instruction
   construction and validation. They do not run a Flow.
2. Codec tests cover the trusted Registry, stored document grammar, JSON round
   trips, portability, and resource limits. They do not compile or run a Flow.
3. Compilation tests cover canonical Flow lowering to native Runic components,
   ports, connections, source maps, and compilation identity.
4. Execution tests cover validation during a call, results, native Runnable
   transitions, errors, process exits, concurrency, and telemetry.

Test error values and runtime failures separately. Test the stable fields and
JSON form of `Jido.Action.Error` or `Jido.Flow.Error` with the data tests. Test
raises, throws, killed workers, caller exits, and nested failures with the
execution tests.

A higher-level test can prove that boundaries connect. Do not repeat the full
lower-level matrix in that test.

## Keep Fixtures Small

Share a fixture when two or more test modules use it or when it belongs to one
central failure or Flow contract set. Keep a small incidental one-use Action or
Flow in its test module. Use small real Actions instead of a general mock layer.

Central fixture modules can provide:

- One valid canonical Flow and its Builder form.
- One complete trusted Registry for Codec tests.
- Small successful Actions.
- Explicit failure Actions for returned errors, raises, throws, exits, and hard
  process kills.
- Named execution forms for a Flow value, Flow module, Flow Instruction, and
  Subflow.

Put shared fixtures under one `test/support/fixtures` tree. Use `action`,
`flow`, `codec`, and `execution` folders. This layout shows the test boundary
and keeps one root namespace. Do not create a different fixture root for each
test file.

Fixture functions must not make assertions. A fixture must not hide the public
contract that the test proves.

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

An Instruction is data for one executable call. Test construction, target
resolution, and merge behavior when the application passes Instructions
between boundaries.

```elixir
test "captures an executable call" do
  assert {:ok, instruction} =
           Jido.Instruction.new(
             target: MyApp.Actions.Add,
             params: %{left: 1, right: 2}
           )

  assert instruction.target == MyApp.Actions.Add
  assert instruction.params == %{left: 1, right: 2}
end
```

Use `Jido.Exec.run/4` for the execution test of the normalized Instruction.
Test Action and Flow targets when the application uses both. Test `start/4`
for an Instruction with a Flow target when the application uses step-wise
execution.

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

Test the canonical graph before testing runtime behavior. Assert component
names, explicit order, inferred dependencies, output shape, and semantic
identity when these are important to the application.

```elixir
test "declares the dependency graph" do
  flow = MyApp.Flows.BuildReport.flow()

  assert {:ok, dependencies} = Jido.Flow.dependencies(flow)
  assert dependencies["build_summary"] == %{
           after: [],
           references: ["load_account", "load_orders"],
           effective: ["load_account", "load_orders"]
         }

  assert {:ok, explanation} = Jido.Flow.explain(flow)
  assert Enum.map(explanation.components, & &1.name) == [
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
  assert {:ok, %{mapped: results, total: %{total: 12}}} =
           Jido.Exec.run(MyApp.Flows.DoubleAndSum, %{values: [1, 2, 3]}, %{})

  assert Enum.map(results, & &1.index) == [0, 1, 2]
  assert Enum.map(results, & &1.value) == [2, 4, 6]
end
```

When `async: true` is important, assert the ordered records and the configured
concurrency boundary. Do not use task completion order as a result assertion.
See [Map and Reduce](flow-collections.livemd).

## Test Iterate And State

Test the initial head condition, the first State update, normal completion,
and exhaustion at `max_iterations`. Assert the complete Iterate result,
including `iterations`, `state`, and `output`.

```elixir
test "commits each iterator state replacement" do
  assert {:ok, %{iterations: 3, state: %{count: 3}, output: %{count: 3}}} =
           Jido.Exec.run(MyApp.Flows.CountThree, %{}, %{})
end

test "can complete before the first body call" do
  assert {:ok, %{iterations: 0, state: %{count: 3}, output: nil}} =
           Jido.Exec.run(MyApp.Flows.CountUntil, %{start: 3, target: 3}, %{})
end
```

Test State schema failures without exposing rejected State values. If the
Iterator body has effects, also test the repeat-risk and idempotency boundary. See
[Iterate and State](flow-iterate-state.livemd).

## Test Nested Flows

Test the child Flow directly for its own graph and behavior. Test the parent
for input mapping, child output mapping, and its native Workflow boundary.

```elixir
test "exposes nested Flow runnables" do
  assert {:ok, execution} =
           Jido.Exec.start(MyApp.Flows.Parent, %{value: 4}, %{})

  assert [%Runic.Workflow.Runnable{} = runnable] = Jido.Exec.ready(execution)
  assert {:ok, %Runic.Workflow.Runnable{status: :completed}, execution} =
           Jido.Exec.step(execution, runnable)

  assert {:ok, execution} = Jido.Exec.continue(execution)
  assert Jido.Exec.status(execution) == :succeeded
end
```

The parent exposes child Steps, validators, and Runic connection work. A
nested Flow inherits the parent's context and execution settings.

## Test Step-wise Execution

Use `start/4` when readiness and manual transitions are part of the contract.
Assert the latest execution after every transition.

```elixir
test "steps through dependency waves" do
  assert {:ok, execution} = Jido.Exec.start(MyApp.Flows.BuildReport, %{account_id: "acct-1"})
  assert Jido.Exec.status(execution) == :running
  assert Enum.all?(Jido.Exec.ready(execution), &match?(%Runic.Workflow.Runnable{}, &1))

  assert {:ok, runnables, execution} = Jido.Exec.wave(execution)
  assert Enum.all?(runnables, &(&1.status == :completed))

  assert {:ok, execution} = Jido.Exec.continue(execution)

  assert Jido.Exec.status(execution) == :succeeded
  assert {:ok, %{account_id: "acct-1", order_count: 1}} = Jido.Exec.result(execution)
end
```

Test that a non-ready runnable ID returns `{:error, error}` and leaves the old
execution unchanged. Test that a terminal execution rejects further steps.

## Test Waves

`wave/1` executes only the nodes that were ready at the start of the call.
This makes dependency boundaries easy to assert without time-based checks.

```elixir
test "executes one ready wave" do
  assert {:ok, execution} = Jido.Exec.start(MyApp.Flows.BuildReport, %{account_id: "acct-wave"})
  assert {:ok, results, execution} = Jido.Exec.wave(execution)

  assert Enum.all?(results, &match?(%Runic.Workflow.Runnable{status: :completed}, &1))
  assert Enum.all?(Jido.Exec.ready(execution), &match?(%Runic.Workflow.Runnable{}, &1))
end
```

## Test Failures And Independent Work

A runnable failure is an applied transition. The step result is
`{:ok, runnable, latest_execution}`, with `runnable.status == :failed`.

```elixir
test "stops after a failure" do
  assert {:ok, execution} = Jido.Exec.start(MyApp.Flows.FailureFlow)
  assert [runnable | _] = Jido.Exec.ready(execution)
  assert {:ok, %Runic.Workflow.Runnable{status: :failed}, execution} =
           Jido.Exec.step(execution, runnable)

  assert Jido.Exec.status(execution) == :failed
  assert Jido.Exec.ready(execution) == []
  assert {:error, _error} = Jido.Exec.result(execution)
end
```

For an asynchronous wave, also test the case where two runnables fail. Assert
that `Jido.Flow.Error.ExecutionFailureError.failures` contains both errors.

Use `capture_log: true` when the failure path emits expected error logs.
Assert error types and important details, not full log formatting.

## Test Parallel Options

The Flow API supports only `async` and `max_concurrency` as policy options.
Test option validation directly, and use `async: true` to test that independent runnables can
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
  assert results
         |> Enum.map(& &1.node.name)
         |> Enum.sort() == ["load_account", "load_orders"]
end

test "rejects unsupported runtime policy" do
  assert {:error, %Jido.Flow.Error.InvalidExecutionError{}} =
           Jido.Exec.start(MyApp.Flows.BuildReport, %{}, %{}, timeout: 100)
end
```

Do not assert elapsed time to prove parallelism. Scheduler load makes timing
tests flaky. Instead, assert the ready set, runnable states, and the stored
option behavior. Ready-list order is not an authoring contract. The current API does not provide retries, backoff,
timeouts, deadlines, cancellation, rewind, or persistence; test those policies
in the higher-level runtime that owns them.
