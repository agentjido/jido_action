# Migration Shims

The v3 beta has removed the Instruction migration shims. Instructions now
contain only `target`, `params`, `context`, and `metadata`. Exec receives all
execution options from its caller.

## Removed Instruction Inputs

| Removed field | Required replacement |
| --- | --- |
| `action` | `target: action_module` |
| `flow` | `target: flow_module` or `target: flow_value` |
| `opts` | Direct options on `Jido.Exec.run/4`, `run_async/4`, or `start/4` |
| `id` | Descriptive `metadata` or caller-owned data |

This is an explicit beta API change. The earlier `flow` input was supported
without a warning; it is now removed with the other fields. The constructor
rejects every removed key, including nil or empty values. It returns a
structured error with the rejected fields. `new!/1` raises the error, and
old struct literals no longer compile.

Use the canonical form:

```elixir
instruction = Jido.Instruction.new!(
  target: MyApp.Actions.SendEmail,
  params: %{to: "user@example.com"},
  metadata: %{id: "send-1"}
)

Jido.Exec.run(instruction, %{}, %{},
  timeout: 5_000,
  task_supervisor: MyApp.TaskSupervisor
)
```

There is no option forwarding, stored-option precedence, or migration warning.
Do not put execution policy in metadata. Move only supported options to Exec;
keep retry, backoff, context propagation policy, logging setup, and telemetry
setup in the caller. `start/4` does not accept a complete-call timeout.

See [Instruction field migration](v2-to-v3-migration.md#replace-instruction-fields)
for the exact construction errors and checked downstream migration paths.

## Supported APIs That Are Not Shims

The following surfaces are part of the version 3 contract. They do not emit
migration warnings:

- the Action `run/2` callback;
- the common two-tuple and three-tuple Action results;
- concrete `Jido.Action.Error` exception types;
- `Jido.Exec.run/4` as the complete-call execution boundary;
- `Jido.Exec.run_async/4`, `await/1`, `await/2`, and `cancel/1` as the
  owner-bound asynchronous execution boundary; and
- `task_supervisor:` local supervisor routing.

`timeout` also remains an Exec option. Its location and default changed. Pass
it to `Jido.Exec.run/4`; the version 3 default is `:infinity`.

These are supported APIs, not temporary aliases. Do not label normal support
as a compatibility shim.

## Removed APIs With No Shim

The package does not add a shim when the old behavior has no safe local meaning
or when version 3 moved the responsibility out of `jido_action`.

### Actions

There is no shim for removed Action metadata options, compensation settings,
NimbleOptions schemas, the five removed lifecycle hooks, generated metadata
functions, Action JSON, or AI tool conversion. Version 3 keeps
`on_before_validate_params/1` as a supported callback. Move the other concerns
to schemas, `run/2`, the caller, or the package that owns the integration.

### Instructions

There is no shim for `id`, `action`, `flow`, `opts`, symbolic Action names, `normalize/3`,
`normalize_single/3`, tuple or list shorthand, or
`validate_allowed_actions/2`. Put descriptive identity in `metadata` or
caller-owned data, and build each Instruction explicitly.

### Execution

There is no shim for automatic retry, backoff, compensation, durable
cancellation policy, Chains, Closures, context propagators, or package
execution defaults. Exec async handles support cancellation of one active,
owner-bound in-memory call. The caller or a higher-level runtime must own the
durable policies.

### Plans, Catalogs, Tools, And Generators

There is no shim for `Jido.Plan`, the Action Catalog, Action Tool conversion,
bundled `Jido.Tools.*`, or the old Mix generators. Use a Flow only when an
explicit executable graph fits the application. Keep catalog, tool, and
integration policy in the package that owns it.

### Storage

There is no v2 Plan-to-Flow or Instruction-to-Flow decoder. Build a canonical
Flow and store it through `Jido.Flow.Codec` with a trusted Registry.
