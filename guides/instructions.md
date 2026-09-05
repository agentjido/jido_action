# Instructions

A `Jido.Instruction` is data for one executable call. It can target an Action
module, a Flow module, or a runtime `%Jido.Flow{}` value.

## Construct An Instruction

```elixir
instruction =
  Jido.Instruction.new!(
    target: MyApp.Actions.SendEmail,
    params: %{to: "user@example.com"},
    context: %{tenant_id: "tenant-1"},
    metadata: %{request_id: "req-1"}
  )
```

The fields have these roles:

| Field | Meaning |
| --- | --- |
| `target` | The Action or Flow to execute. |
| `params` | Input for the target. |
| `context` | Caller-owned runtime data. |
| `metadata` | Caller data with no execution meaning in this package. |

Use `new/1` when construction can fail.

```elixir
case Jido.Instruction.new(target: MyApp.Actions.SendEmail) do
  {:ok, instruction} -> {:ok, instruction}
  {:error, error} -> {:error, Exception.message(error)}
end
```

Use `target:` for Action modules, Flow modules, and runtime Flow values:

```elixir
flow_instruction = Jido.Instruction.new!(target: MyApp.Flows.DeliverOrder)
```

The constructor accepts maps with atom keys or keyword lists. Params, context,
and metadata can be maps, keyword lists, or nil. Nil becomes an empty map.
The target is required; explicit nil is an invalid executable target.

A field value of `false` is invalid, including in a raw Instruction struct.
Constructors reject it. Exec returns a structured error before Action work
starts. A `false` value inside a valid map remains valid call data.

The `action`, `flow`, and `opts` fields have been removed from the beta API.
The constructor rejects these keys even when a valid `target` is also present
or the removed value is nil or empty. The earlier `id` field stays removed.
`new/1` returns a structured error; `new!/1` raises it. Old struct literals
with removed fields no longer compile. See
[Instruction migration](v2-to-v3-migration.md#replace-instruction-fields).

## Execute An Instruction

```elixir
Jido.Exec.run(instruction)
```

Call-site parameter and context maps override equal keys in the Instruction.
The merge is shallow: an incoming nested map replaces the stored nested map.
Metadata stays unchanged and is not passed to the target as execution policy.

```elixir
Jido.Exec.run(
  instruction,
  %{to: "new@example.com"},
  %{tenant_id: "tenant-2"}
)
```

An Instruction uses the rules of its resolved target. All run-to-completion
targets accept direct Exec options `timeout:`, `task_supervisor:`, `max_continuations:`, and
`max_concurrency:`. An Action does not use `max_concurrency` itself, but it can
continue to a Flow. An Instruction can be a target for `Jido.Exec.run_async/4`.

Only a Flow Instruction supports step-wise execution.

```elixir
{:ok, execution} = Jido.Exec.start(flow_instruction)
{:ok, execution} = Jido.Exec.continue(execution)
Jido.Exec.result(execution)
```

## Boundary

An Instruction does not contain Flow structure or runtime policy. It is not a
general JSON form because module atoms and runtime Flow values do not have one
portable representation. Use `Jido.Flow.Codec` to store a Flow definition.
Choose an application-owned format if you must store Instructions.
