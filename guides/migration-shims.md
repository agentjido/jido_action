# Migration Shims

Jido Action 3 makes the package smaller and gives each public type one clear
role. Some version 2 source forms cannot compile against the new structs. A
small set of migration shims accepts these forms so an application can run its
tests and replace them in normal source edits.

This guide defines the shim policy for the full package. It lists the active
shims, the APIs that remain supported without a shim, and the removed APIs that
do not have a shim.

## Deprecation Policy

Migration shims are deprecated public compatibility paths. New code must not
use them. This guide does not assign a removal release. A removal decision
requires a separate compatibility review and clear release notes.

Treat each warning as migration work. Do not filter these warnings as a
permanent application setting.

## Shim Design Rules

Jido uses a shim only when it can recover the old intent without making the new
contract unclear.

A package shim must follow these rules:

1. Accept only the smallest old source form needed for migration.
2. Validate the old value against the current type or execution contract.
3. Convert it to the current canonical form before normal work starts.
4. Emit a direct Logger warning when Jido uses deprecated input.
5. Do not put option values or Logger metadata in the warning.
6. Give an explicit current API replacement.
7. Do not restore a removed package responsibility.
8. Return an error when Jido cannot determine a safe current meaning.

Explicit current API input has precedence over shim input. This lets a caller
move policy one setting at a time.

## Compatibility Results

A version 2 surface has one of these results:

| Result | Meaning |
| --- | --- |
| Normalize and continue | Jido can convert the old input to the current data model. |
| Forward and continue | The current runtime still supports the setting at a different boundary. |
| Warn and leave out | Jido recognizes the setting, but version 3 no longer performs that policy. |
| Warn and return an error | The field compiles, but Jido cannot safely map the value. |
| No shim | The old API or responsibility was removed and requires an application change. |

## Active Package Shims

The current package has two intentional version 2 migration shims:

| Surface | Result | Current form |
| --- | --- | --- |
| `Jido.Instruction.action` | Validate as an Action, warn, and normalize | `Jido.Instruction.target` |
| `Jido.Instruction.opts` | Classify, warn, forward supported keys, and leave out removed keys | Options on `Jido.Exec.run/4` or caller policy |

The `flow:` Instruction constructor input is not a version 2 shim. It is a
typed version 3 input. It validates a Flow target and stores it in `target`
without a deprecation warning. Use `target:` as the normal form.

## Instruction Target Shim

Version 2 Instructions use `action`:

```elixir
instruction = %Jido.Instruction{
  action: MyApp.Actions.SendEmail,
  params: %{to: "user@example.com"}
}
```

Version 3 accepts this constructor key and struct field. Jido confirms that
the value is an Action, warns, and normalizes it:

```elixir
instruction = %Jido.Instruction{
  target: MyApp.Actions.SendEmail,
  params: %{to: "user@example.com"}
}
```

The neutral `target` field is required because an Instruction can now target
an Action module, a Flow module, or a runtime `%Jido.Flow{}` value.

Conflicting target fields return an error. An `action:` value that resolves to
a Flow also returns an error. The shim does not weaken target-kind validation.

## Instruction Options Shim

Version 2 can store execution policy in the Instruction:

```elixir
instruction = %Jido.Instruction{
  action: MyApp.Actions.SendEmail,
  params: %{to: "user@example.com"},
  opts: [timeout: 5_000]
}
```

Version 3 accepts `opts` so this literal compiles. `Jido.Exec.run/4` consumes a
non-empty field and emits one grouped warning. Move the option to the execution
call:

```elixir
instruction = %Jido.Instruction{
  target: MyApp.Actions.SendEmail,
  params: %{to: "user@example.com"}
}

Jido.Exec.run(instruction, %{}, %{}, timeout: 5_000)
```

Direct Exec options have precedence during migration:

```elixir
legacy_instruction = %Jido.Instruction{
  target: MyApp.Actions.SendEmail,
  opts: [timeout: 5_000]
}

# Uses 10 seconds and warns about the legacy Instruction opts.
Jido.Exec.run(legacy_instruction, %{}, %{}, timeout: 10_000)
```

### Option Results

| Version 2 option | Version 3 result | Migration |
| --- | --- | --- |
| `timeout` | Forwarded by `run/4` | Pass it directly to `Jido.Exec.run/4`. |
| `jido` | Forwarded | Pass it directly to `Jido.Exec.run/4` or `start/4`. |
| `max_retries` | Warned and not applied | Put retry count in the caller or Jido runtime. |
| `backoff` | Warned and not applied | Put retry delay in the caller or Jido runtime. |
| `log_level` | Warned and not applied | Configure logging at the application boundary. |
| `telemetry` | Warned and not applied | Configure telemetry handlers outside the Instruction. |
| `context_propagators` | Warned and not applied | Propagate context at the caller-owned Task or runtime boundary. |
| `context_propagator_failure_mode` | Warned and not applied | Own propagation failure policy at the same boundary. |
| `error_normalization` | Warned and not applied | Remove it. Version 3 always uses its canonical errors. |
| Any other key | Warning and execution error | Inspect the old use and move or remove it explicitly. |

When retry settings are present, the warning states that the call runs once.
Jido Action 3 does not retry an Action or Flow.

The shim does not log option values. It logs option keys, the resolved target,
and the required migration. An empty `opts: []` field does not warn.

`Jido.Exec.start/4` does not accept `timeout`. A paused Flow has no active
whole-call timeout. A legacy timeout on an Instruction passed to `start/4`
warns and returns the normal invalid-option error.

## Supported APIs That Are Not Shims

Some version 2 surfaces remain part of the version 3 contract. They do not emit
migration warnings:

- the Action `run/2` callback;
- the common two-tuple and three-tuple Action results;
- concrete `Jido.Action.Error` exception types;
- `Jido.Exec.run/4` as the complete-call execution boundary; and
- `jido:` instance routing.

`timeout` also remains an Exec option. Its location and default changed. Pass
it to `Jido.Exec.run/4`; the version 3 default is `:infinity`.

These are supported APIs, not temporary aliases. Do not label normal support
as a compatibility shim.

## Removed APIs With No Shim

The package does not add a shim when the old behavior has no safe local meaning
or when version 3 moved the responsibility out of `jido_action`.

### Actions

There is no shim for removed Action metadata options, compensation settings,
NimbleOptions schemas, lifecycle hooks, generated metadata functions, Action
JSON, or AI tool conversion. Move these concerns to schemas, `run/2`, the
caller, or the package that owns the integration.

### Instructions

There is no shim for `id`, symbolic Action names, `normalize/3`,
`normalize_single/3`, tuple or list shorthand, or
`validate_allowed_actions/2`. Put descriptive identity in `metadata` or
caller-owned data, and build each Instruction explicitly.

### Execution

There is no shim for automatic retry, backoff, compensation, asynchronous
handles, cancellation, Chains, Closures, context propagators, or package
execution defaults. The caller or a higher-level runtime must own these
policies.

### Plans, Catalogs, Tools, And Generators

There is no shim for `Jido.Plan`, the Action Catalog, Action Tool conversion,
bundled `Jido.Tools.*`, or the old Mix generators. Use a Flow only when an
explicit executable graph fits the application. Keep catalog, tool, and
integration policy in the package that owns it.

### Storage

There is no v2 Plan-to-Flow or Instruction-to-Flow decoder. Build a canonical
Flow and store it through `Jido.Flow.Codec` with a trusted Registry.

## Why The Package Uses Narrow Shims

Struct field changes can stop compilation before tests or migration tools can
inspect the application. The `action` and `opts` fields let the compiler pass
these old literals to a runtime boundary that can give a precise warning.

The shims stop at that boundary. They do not make removed retry, compensation,
catalog, tool, or storage behavior part of the new core package.

This keeps migration observable while it protects the version 3 design:

- Instructions hold stable call data;
- Exec owns one call boundary;
- callers own runtime and orchestration policy; and
- Flows define explicit graph structure and data paths.

## Warning Policy

Migration warnings use `Logger.warning/1` without added Logger metadata.

- The `action` warning identifies the target and says to use `target`.
- The `opts` warning groups all keys for one execution.
- Warning text lists keys, not values.
- Known removed option keys state that they are not applied.
- Unknown keys state that Jido cannot continue.
- Empty compatibility fields do not warn.
- Repeated use can warn again; Jido does not keep global suppression state.

## Package Migration Check

1. Replace Instruction `action:` with `target:`.
2. Move Instruction `opts` to each `Jido.Exec` call or caller policy.
3. Move descriptive Instruction identity to metadata or caller-owned data.
4. Convert Action schemas and remove old Action options and hooks.
5. Move retry, compensation, cancellation, and context propagation to the
   caller or Jido runtime.
6. Replace Plans, catalogs, tools, and generators only where the application
   still needs those concerns.
7. Treat stored Flows as a new version 3 format.
8. Run tests without hiding Logger warnings.
9. Search again for removed modules, fields, callbacks, and options.

When the application runs without migration warnings and no removed APIs
remain, it no longer depends on package migration shims.
