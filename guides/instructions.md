# Instructions

An `Instruction` is a small invocation data type. It describes one requested
executable call:

```elixir
%Jido.Instruction{
  target: MyApp.Actions.NormalizeEmail,
  params: %{email: "user@example.com"},
  context: %{tenant_id: "tenant-1"},
  metadata: %{request_id: "req-1"}
}
```

The target follows the `Jido.Executable` contract. It can be an Action module,
a Flow module, or a runtime `%Jido.Flow{}` value.

An Instruction does not define a graph, source program, checkpoint, or
execution policy. If its target is a Flow, that Flow contains the graph.

## Create An Instruction

Use `new/1` when you want an explicit result:

```elixir
{:ok, instruction} =
  Jido.Instruction.new(
    target: MyApp.Actions.NormalizeEmail,
    params: %{email: "USER@EXAMPLE.COM"},
    context: %{request_id: "req-1"}
  )
```

Use `new!/1` when invalid configuration must raise:

```elixir
instruction =
  Jido.Instruction.new!(
    target: MyApp.Actions.NormalizeEmail,
    params: %{email: "USER@EXAMPLE.COM"}
  )
```

The `:target` field is required. `:params`, `:context`, and `:metadata` default
to `%{}`. Each invocation field can be a map or a keyword list. Jido converts a
keyword list to a map and converts `nil` to `%{}`.

The constructor resolves the target through `Jido.Executable`. It does not
validate target parameters or output. That validation occurs during execution.
Constructor shape errors use `Jido.Action.Error.InvalidInputError`. Unknown
targets use `Jido.Action.Error.ConfigurationError` because the resolver does
not yet know an executable kind.

## Execute An Action Instruction

Pass an Instruction to `Jido.Exec.run/4`:

```elixir
instruction =
  Jido.Instruction.new!(target: MyApp.Actions.Add, params: %{left: 2})

{:ok, %{result: 5}} =
  Jido.Exec.run(instruction, %{right: 3}, %{trace_id: "trace-1"})
```

`Jido.Exec` merges call-site keys over the stored parameter and context keys.
It then uses the target adapter. An Action target keeps the Action input,
output, error, and extras rules. An Action target accepts common `jido:`
instance routing. It does not accept Flow policy options and cannot start a
step-wise execution.

## Execute A Flow Instruction

A Flow module or runtime Flow target uses the same Flow execution rules:

```elixir
instruction =
  Jido.Instruction.new!(
    target: MyApp.Flows.BuildReport,
    params: %{account_id: "acct-1"}
  )

{:ok, report} =
  Jido.Exec.run(instruction, %{}, %{}, async: true, max_concurrency: 4)
```

You can also start the Flow target and use the native Runic step-wise surface:

```elixir
{:ok, execution} = Jido.Exec.start(instruction)
[%Runic.Workflow.Runnable{} | _] = Jido.Exec.ready(execution)
{:ok, execution} = Jido.Exec.continue(execution)
{:ok, report} = Jido.Exec.result(execution)
```

The Instruction does not change the Flow graph or its canonical data. It only
supplies the target, parameters, and context for one invocation.

## Contract Boundaries

Each target must resolve through `Jido.Executable`. Action and Flow modules use
the common Action-compatible callbacks `run/2`, `validate_params/1`, and
`validate_output/1`. A Flow module also exports `flow/0`. A runtime Flow value
is resolved directly.

Use `Jido.Executable.validate/1` when a caller must check the resolved target
contract before execution.

## What An Instruction Does Not Do

An Instruction does not:

- compose multiple executable targets,
- describe dependencies or Flow output expressions,
- run a target when it is created,
- select retry or timeout policy, or
- store a durable execution checkpoint.

Use a [Flow](flows.md) for composition and
[Jido.Exec](execution.md) for execution behavior.
