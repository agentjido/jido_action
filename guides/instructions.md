# Jido.Instruction

`Jido.Instruction` is a small call frame for one action execution. It stores an
action module, params, and context as plain data.

Use an instruction when a caller must pass, queue, inspect, or enrich one
action call before execution.

## Create An Instruction

```elixir
{:ok, instruction} =
  Jido.Instruction.new(
    action: MyApp.Actions.NormalizeEmail,
    params: %{email: "ADA"},
    context: %{default_domain: "example.org"}
  )
```

Use `new!/1` when invalid construction must raise:

```elixir
instruction =
  Jido.Instruction.new!(
    action: MyApp.Actions.NormalizeEmail,
    params: [email: "ADA"],
    context: [default_domain: "example.org"]
  )
```

Params and context can be maps or keyword lists. `nil` becomes an empty map.
The action is required and must be a non-`nil` atom.

## Construction And Contract Validation

Instruction construction validates the call-frame shape. It does not load the
action module or validate the action callbacks. This separation lets an
instruction exist before execution.

`Jido.Exec` checks that the action provides these functions before it runs the
instruction:

- `run/2`
- `validate_params/1`
- `validate_output/1`

You can check the contract without execution:

```elixir
:ok = Jido.Instruction.validate_action_contract(MyApp.Actions.NormalizeEmail)
```

## Run An Instruction

```elixir
{:ok, %{email: "ada@example.org"}} = Jido.Exec.run(instruction)
```

`Jido.Exec` uses the instruction params and context as the action call input.
It applies the same validation, output checks, and error normalization that it
applies to an action module.

## Add Call-Site Values

The second and third arguments to `Jido.Exec.run/3` add input and context to an
existing instruction:

```elixir
instruction =
  Jido.Instruction.new!(
    action: MyApp.Actions.NormalizeEmail,
    params: %{email: "ADA", source: :stored},
    context: %{request_id: "req-old"}
  )

{:ok, result} =
  Jido.Exec.run(
    instruction,
    %{email: "GRACE"},
    %{request_id: "req-new", default_domain: "example.org"}
  )
```

Call-site maps merge over stored maps. In this example, the executed params
contain `email: "GRACE"` and `source: :stored`. The executed context contains
the new request ID and the default domain.

You can apply the same merge without execution:

```elixir
merged =
  Jido.Instruction.normalize!(
    instruction,
    %{email: "GRACE"},
    %{request_id: "req-new"}
  )
```

## Keep The Boundary Small

An instruction does not contain these items:

- a workflow or dependency graph
- retry, timeout, or fallback policy
- a source-language program
- scheduling or persistence state

Use `Jido.Flow` for a static graph of action calls. Put runtime policy in the
caller or in a higher runtime package.
