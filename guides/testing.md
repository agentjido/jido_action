# Testing

Test author data, Action behavior, compilation, and runtime behavior at their
own public boundaries.

## Test Flow Data Without Running Work

```elixir
assert {:ok, %Jido.Flow{} = flow} = Jido.Flow.new(definition)
assert {:ok, dependencies} = Jido.Flow.dependencies(flow)
assert {:ok, explanation} = Jido.Flow.explain(flow)
```

Use `Jido.Flow.validate/1` when the test must stay inert. Use
`Jido.Exec.compile/2` when it must also verify Action and child Flow targets.

## Test Codec And Registry

```elixir
assert {:ok, document, registry} = Jido.Flow.Codec.encode(flow)
assert {:ok, restored} = Jido.Flow.Codec.decode(document, registry)
assert Jido.Flow.to_map(restored) == Jido.Flow.to_map(flow)
```

Add tests for unknown identifiers, unsupported values, limits, and atom safety
when an application stores user-supplied Flow documents.

## Test Native Compilation

```elixir
assert {:ok, %Runic.Workflow{} = workflow} = Jido.Exec.compile(flow)
assert Runic.Workflow.build_log(workflow) != []
```

Compare stable component IDs when definition storage and recovery depend on
them. Do not assert private graph fields.

## Test Actions And Exec Separately

Test `validate_params/1`, `run/2`, and `validate_output/1` directly for Action
unit behavior. Add an Exec test to prove that validation and errors cross the
Runic Runnable boundary correctly.

```elixir
assert {:ok, %{value: 2}} =
         Jido.Exec.run(MyApp.Actions.Increment, %{value: 1})
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
4. call `Runic.Runner.resume/3`;
5. assert that completed Actions did not run again;
6. inspect results through `Runic.Runner.get_results/2`.

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
