# Instructions

An `Instruction` is a small call-frame data type. It describes one requested
Action execution:

```elixir
%Jido.Instruction{
  action: MyApp.Actions.NormalizeEmail,
  params: %{email: "user@example.com"},
  context: %{tenant_id: "tenant-1"}
}
```

An Instruction is not a Flow, graph, source program, checkpoint, or execution
policy. It is data for one Action call.

## Create An Instruction

Use `new/1` when you want an explicit result:

```elixir
{:ok, instruction} =
  Jido.Instruction.new(
    action: MyApp.Actions.NormalizeEmail,
    params: %{email: "USER@EXAMPLE.COM"},
    context: %{request_id: "req-1"}
  )
```

Use `new!/1` when invalid configuration should raise:

```elixir
instruction =
  Jido.Instruction.new!(
    action: MyApp.Actions.NormalizeEmail,
    params: %{email: "USER@EXAMPLE.COM"}
  )
```

The `:action` field is required and must be a non-nil module atom. `:params`
and `:context` default to `%{}`. Each can be a map or a keyword list. Keyword
lists are normalized to maps; `nil` is normalized to `%{}`.

Invalid attributes return a `Jido.Action.Error.InvalidInputError` or a small
construction reason such as `:missing_action` or `:invalid_action`.

## Execute An Instruction

Pass an Instruction to `Jido.Exec.run/4`:

```elixir
instruction = Jido.Instruction.new!(action: MyApp.Actions.Add, params: %{left: 2})

{:ok, %{result: 5}} =
  Jido.Exec.run(instruction, %{right: 3}, %{trace_id: "trace-1"})
```

`Jido.Exec` normalizes the stored and call-site maps. It merges call-site keys
over stored keys, validates the final parameters, and validates the Action
output. It also preserves Action extras for a direct Instruction call.

Instructions do not have `step/1`, `wave/1`, or `continue/1` operations. Those
step-wise functions apply only to Flow executions.

## Contract Boundaries

The referenced Action must be loadable and export `run/2`,
`validate_params/1`, and `validate_output/1`. `Jido.Exec` checks this contract
when it executes the Instruction.

The Instruction itself does not validate the Action's parameter schema during
construction. Parameter and output validation occur at the execution boundary.

## What An Instruction Does Not Do

An Instruction does not:

- compose multiple Actions,
- describe dependencies or return expressions,
- run an Action when it is created,
- select retry or timeout policy, or
- store a durable execution checkpoint.

Use a [Flow](flows.md) for composition and
[Jido.Exec](execution.md) for execution behavior.
