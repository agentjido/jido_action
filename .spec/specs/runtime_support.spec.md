# Jido.Action Runtime Support

Supports package requirement `jido_action.package.runtime_support`.

## Intent

Define the shared runtime support layer for errors, utility helpers, and the
global task supervision used by Jido.Action execution.

```spec-meta
id: jido_action.runtime_support
kind: policy
status: active
summary: Shared errors, utility helpers, and global execution supervision for Jido.Action.
surface:
  - lib/jido_action/application.ex
  - lib/jido_action/error.ex
  - lib/jido_action/util.ex
```

## Requirements

```spec-requirements
- id: jido_action.runtime.error_helpers
  statement: Jido.Action.Error shall expose concrete exception structs and helper constructors for validation, execution, configuration, timeout, and internal failures.
  priority: must
  stability: stable
- id: jido_action.runtime.utility_helpers
  statement: Jido.Action.Util shall provide conditional logging, name validation, and result normalization helpers for action runtime code.
  priority: must
  stability: stable
- id: jido_action.runtime.global_supervision
  statement: The package runtime shall provide a default task supervisor for Jido.Exec when no instance-specific supervisor is selected.
  priority: must
  stability: stable
```

## Verification

```spec-verification
- kind: command
  target: MIX_ENV=test mix test test/jido_action/error_test.exs test/jido_action/util_test.exs test/jido_action/exec_timeout_task_supervisor_test.exs test/jido_action/exec/instance_isolation_test.exs
  execute: true
  covers:
    - jido_action.runtime.error_helpers
    - jido_action.runtime.utility_helpers
    - jido_action.runtime.global_supervision
```
