# Testing

Test the package as four connected boundaries: data, Codec, compilation, and
execution. Give each behavior one primary test owner.

## Test Data Without Running Work

Data tests cover:

- Action and Instruction construction;
- component constructors;
- Flow expressions and reference scopes;
- Flow graph validation;
- explicit and inferred dependencies; and
- semantic identity.

```elixir
test "declares a result dependency" do
  flow = MyApp.Flows.BuildReport.flow()

  assert {:ok, dependencies} = Jido.Flow.dependencies(flow)

  assert dependencies["summary"] == %{
           after: [],
           references: ["load"],
           effective: ["load"]
         }
end
```

Use `Jido.Flow.validate/1` for inert structure checks. Use
`validate_executable/1` only when the test must check target contracts.

## Test Codec And Registry

Codec tests own:

- Registry validation and aliases;
- encode and decode parity;
- real JSON byte round trips;
- exact stored keys and version;
- unknown identifier errors;
- UTF-8, depth, width, and total-node limits; and
- the rule that decode does not execute work.

```elixir
{:ok, document} = Jido.Flow.Codec.encode(flow, registry)
json = Jason.encode!(document)
{:ok, restored} = Jido.Flow.Codec.decode(Jason.decode!(json), registry)

assert Jido.Flow.to_map(restored) == Jido.Flow.to_map(flow)
```

Do not use `Jido.Flow.to_map/1` as the stored format.

## Test Native Compilation

Compilation tests own the mapping from canonical components to native Runic
constructs. Assert ports, connections, cardinality, Join, InputBinding,
FanOut, FanIn, nested Workflow boundaries, source maps, and compilation
identity where those facts are part of the contract.

```elixir
assert {:ok, %Jido.Flow.Compiled{} = compiled} =
         Jido.Flow.compile(flow)

assert %Runic.Workflow{} = compiled.workflow
```

Do not make an internal compiler module public for a test.

## Test Action Behavior And Exec Separately

Call `run/2` directly for the Action business rule.

```elixir
test "adds values" do
  assert {:ok, %{value: 3}} =
           MyApp.Actions.Add.run(%{left: 1, right: 2}, %{})
end
```

Then test the public boundary for validation, output normalization, process
failure, and error conversion.

```elixir
test "rejects invalid input before work" do
  assert {:error, %Jido.Action.Error.InvalidInputError{}} =
           Jido.Exec.run(MyApp.Actions.Add, %{left: "1", right: 2})
end
```

Include returned errors, raises, throws, exits, and hard process kills when the
application relies on those boundaries. Assert process cleanup as well as the
returned error.

## Test Flow Results And Transitions

Run-to-completion tests own final values and Flow errors.

```elixir
assert {:ok, expected} =
         Jido.Exec.run(MyApp.Flows.BuildReport, input)
```

Step-wise tests own readiness and state transitions.

```elixir
assert {:ok, execution} =
         Jido.Exec.start(MyApp.Flows.BuildReport, input)

assert Enum.all?(
         Jido.Exec.ready(execution),
         &match?(%Jido.Exec.Work{}, &1)
       )

assert {:ok, _runnables, execution} = Jido.Exec.wave(execution)
assert {:ok, execution} = Jido.Exec.continue(execution)
assert Jido.Exec.result(execution) == {:ok, expected}
```

Always bind the newest Execution value. Add a focused test that an old revision
fails before work starts.

A failed runnable is an applied transition. `step/2` can return `:ok` with a
Work whose status is `:failed`. Read the terminal error with `result/1`.

## Test Components At Their Semantic Boundary

For Choice, test every option, first-match order, and fallback. Confirm that a
selected target failure does not run fallback.

For Map, test input order, empty input, both error modes, and concurrent order
preservation. For Reduce, use a non-associative example to prove serial source
order and test the empty collection.

For Iterate, test zero-iteration completion, State replacement, normal
completion, State schema rejection, and exhaustion without one extra body
call.

For Subflow, test the child directly, then test the parent input and output
mapping. Use Work paths and roles to test child stopping points. Keep native shape
assertions in compiler tests or explicit `Jido.Exec.native/1` inspection tests.

## Keep Concurrent Tests Deterministic

Do not use elapsed time or `Process.sleep/1` as synchronization.

- Give each worker a unique reference.
- Make each worker send a ready message.
- Release work with an explicit message.
- Monitor workers and callers when exit behavior matters.
- Use a confirmed barrier before `refute_received/1`.
- Assert canonical result order, not task completion order.
- Stop Tasks and helper processes in the test or `on_exit/1`.
- Use `async: false` for global names, application environment, or shared
  telemetry state.

Use unique telemetry handler IDs. Detach every handler in `on_exit/1`.

## Centralize Only Shared Fixtures

Place shared fixtures under `test/support/fixtures` with `action`, `flow`,
`codec`, and `execution` folders. Keep a one-use incidental fixture in its test
module. A fixture function must not make assertions or hide the public
contract under test.

A small end-to-end test can prove that DSL, direct constructors, Builder, and
Codec converge. Do not repeat every lower-level case in that combined test.
