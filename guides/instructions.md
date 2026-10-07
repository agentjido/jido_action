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
| `kind` | The resolved `:action` or `:flow` kind. |
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

An existing Instruction can be the target of another Instruction. Construction
flattens it to one value. Outer params, context, and metadata replace equal
inner keys. Exec refreshes `kind` from the loaded target module before each
execution, so a retained kind does not select the adapter after a code reload.

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

An Instruction accepts the [Exec options](configuration.md) of its target.

Use a supervised Runic Runner for managed execution:

```elixir
{:ok, _worker} =
  Jido.Exec.start(MyApp.Runner, "delivery-1", flow_instruction, %{}, %{},
    checkpoint_strategy: :every_cycle
  )
```

## Use An Inert Template

`template/2` records a declared target kind without loading the module or
binding runtime data:

```elixir
template = Jido.Instruction.template(:action, MyApp.Actions.SendEmail)
```

`bind/4` checks the loaded target and creates a resolved Instruction with
concrete call data:

```elixir
{:ok, instruction} =
  Jido.Instruction.bind(
    template,
    %{to: "user@example.com"},
    %{tenant_id: "tenant-1"},
    %{request_id: "req-1"}
  )
```

A canonical Flow call stores `{template, params_expression}`. The template has
empty params and context. Exec adds Flow location metadata, validates and binds
the template with the current context, and attaches the evaluated parameter
value. This lets Flow use the same Instruction target model as a direct call
without putting runtime values in the authoring graph.

## Boundary

An Instruction does not contain Flow structure or runtime policy. It is not a
general JSON form because module atoms and runtime Flow values do not have one
portable representation. Use `Jido.Flow.Codec` to store a Flow definition.
Choose an application-owned format if you must store Instructions.

Flow call nodes keep Instruction templates beside their parameter expressions.
Map definitions still use `action` or `flow` module fields; `Jido.Flow.new/1`
creates the templates. They do not accept bound Instructions. Direct Exec calls
accept bound Instructions.
