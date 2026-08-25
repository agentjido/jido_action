# Migrate To v3

Version 3 is a deliberate break from the v2 Action execution helpers and the
earlier Flow spike. It defines one Action-compatible Flow model and one native
Runic execution path. No compatibility aliases or stored-record inference are
included.

## Update The Package Boundary

Use these four public parts:

- `Jido.Action` defines executable leaf work;
- `Jido.Instruction` stores one Action or Flow call;
- `Jido.Flow` defines canonical workflow data; and
- `Jido.Exec` owns execution and errors.

Remove use of legacy Action catalogs, tools, plans, Action Exec helpers,
retry helpers, compensation helpers, and Action-owned supervisors. Move
durable orchestration policy to the higher-level runtime that owns it.

## Update Flow Data Names

Replace old authoring fields with the canonical names:

| Old | v3 |
| --- | --- |
| `nodes` | `components` |
| `return` | `output` |
| `Jido.Flow.Node` | `Jido.Flow.Step` |
| `Jido.Flow.Iterator` | `Jido.Flow.Iterate` |
| `input` on a component | `params` |
| `deps` | `after` |
| `provenance` | `meta` |

Every Flow must declare `output`. Result references create dependencies. Do
not copy inferred dependencies into `after`.

The public Spark DSL shape keeps `step`, `choice`, `map`, `reduce`, `iterate`,
`state`, `while`, `repeat`, and `output`.

## Update Nested Flows

A DSL or Builder `step` becomes `Jido.Flow.Subflow` when its target has exact
executable kind `:flow`.

Choice option, Choice fallback, Map, Reduce, and Iterate targets must be
Actions. Redesign any earlier Flow target in those slots.

## Update Instructions

Replace the Action-specific field:

```elixir
# v2
%Jido.Instruction{action: MyApp.Actions.SendEmail}

# v3
Jido.Instruction.new!(
  target: MyApp.Actions.SendEmail,
  params: %{to: "user@example.com"}
)
```

`target` can be an Action module, Flow module, or runtime Flow value. There is
no `action` field alias.

## Update Stored Flows

Use Codec with a trusted Registry.

```elixir
{:ok, document} = Jido.Flow.Codec.encode(flow, registry)
json = Jason.encode!(document)

{:ok, restored} =
  json
  |> Jason.decode!()
  |> Jido.Flow.Codec.decode(registry)
```

Stored documents use explicit component kinds and canonical field names. This
is the initial stored format. Codec does not read old record shapes or infer
modules.

## Update Execution

Use `Jido.Exec.run/4` for complete Action, Instruction, or Flow calls. Use
`start/4`, `ready/1`, `step/1`, `step/2`, `wave/1`, `continue/1`, and
`result/1` for step-wise Flows.

Step-wise execution now exposes native `Runic.Workflow.Runnable` values. Remove
matches on `Jido.Exec.NodeResult`. Remove use of
`Jido.Flow.Compiler.MapResult`. A Map produces one ordered result list at a
scalar boundary.

`Jido.Flow.compile/2` returns `Jido.Flow.Compiled`. It is derived runtime data,
not a Flow authoring or storage form.

Runtime policy is smaller:

- `run/4` supports one complete-call `timeout`;
- all calls support `jido` instance routing;
- Flows support `async` and `max_concurrency`; and
- automatic retry, compensation, public cancellation, and persistence are not
  in this package.

## Update Errors

Flow definition and execution failures now use `Jido.Flow.Error`. Replace
`Jido.Exec.FlowFailureError` matches with
`Jido.Flow.Error.ExecutionFailureError`.

An Action failure inside a Flow keeps its `Jido.Action.Error` type when
possible. Use `Jido.Flow.Error.to_map/1` at a Flow boundary. Unknown executable
targets use `Jido.Action.Error.ConfigurationError` because resolution fails
before Jido knows the target kind.

## Verify The Migration

For each important Flow:

1. compile with warnings as errors;
2. call `Jido.Flow.validate_executable/1`;
3. compare DSL, direct, Builder, and Codec canonical values when used;
4. round-trip stored data through real JSON bytes;
5. inspect `Jido.Flow.compile/2` for the expected native graph;
6. compare run-to-completion and step-wise final results; and
7. test timeout, process exit, and cleanup behavior at the Exec boundary.

See [Flows](flows.md), [Direct Construction And Builder](flow-builder.md), and
[Executing Flows](flow-execution.livemd) for the v3 contracts.
