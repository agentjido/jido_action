# Action Contract

Supports package requirement `jido_action.package.actions`.

## Intent

Define how Jido.Action turns modules into validated, composable actions
with metadata, schemas, and lifecycle hooks.

```spec-meta
id: jido_action.action_contract
kind: contract
status: active
summary: Core action behavior and lifecycle contract for Jido.Action modules.
surface:
  - lib/jido_action.ex
  - guides/actions-guide.md
```

## Requirements

```spec-requirements
- id: jido_action.action.metadata_schema
  statement: use Jido.Action shall let action modules declare validated metadata plus input and output schemas.
  priority: must
  stability: stable
- id: jido_action.action.lifecycle_hooks
  statement: The action contract shall support lifecycle hooks around parameter validation and execution so actions can extend behavior without custom runners.
  priority: must
  stability: stable
```

## Verification

```spec-verification
- kind: command
  target: MIX_ENV=test mix test test/jido_action/action_test.exs test/jido_action/on_after_run_test.exs
  execute: true
  covers:
    - jido_action.action.metadata_schema
    - jido_action.action.lifecycle_hooks
```
