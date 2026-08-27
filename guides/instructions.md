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

The constructor also accepts typed target inputs. `action:` must resolve to an
Action, and `flow:` must resolve to a Flow. Both inputs become the canonical
`target` field.

```elixir
action_instruction = Jido.Instruction.new!(action: MyApp.Actions.SendEmail)
flow_instruction = Jido.Instruction.new!(flow: MyApp.Flows.DeliverOrder)
```

The `action:` form exists for version 2 migration and emits a runtime warning.
An old struct literal also compiles and is normalized when it enters
`Jido.Instruction` or `Jido.Exec`:

```elixir
%Jido.Instruction{action: MyApp.Actions.SendEmail, params: %{to: address}}
```

Use `target:` in new code. The compatibility path does not restore the removed
`id` field.

Version 3 also accepts the deprecated `opts` field so old struct literals
compile. Exec warns when it consumes a non-empty value. It forwards `timeout`
and `jido`, leaves out known settings that version 3 removed, and rejects
unknown settings. Move all execution options to `Jido.Exec.run/4`. See
[Migration Shims](migration-shims.md) for the package policy and exact option
rules.

## Execute An Instruction

```elixir
Jido.Exec.run(instruction)
```

Call-site parameter and context maps override equal keys in the Instruction.

```elixir
Jido.Exec.run(
  instruction,
  %{to: "new@example.com"},
  %{tenant_id: "tenant-2"}
)
```

An Instruction uses the rules of its resolved target. An Action Instruction
accepts common options such as `timeout:` and `jido:`. A Flow Instruction also
accepts `async:` and `max_concurrency:`.

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
