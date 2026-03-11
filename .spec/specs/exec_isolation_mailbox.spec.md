# Jido.Exec Isolation And Mailbox Hygiene

Supports package requirement `jido_action.package.execution_isolation`.

## Intent

Define how Jido.Exec isolates tenant-specific supervision and keeps async or
compensation task messages from leaking into the caller mailbox.

```spec-meta
id: jido_action.exec.isolation_mailbox
kind: workflow
status: active
summary: Instance supervision, async ownership, and mailbox hygiene for Jido.Exec.
surface:
  - lib/jido_action/exec/async.ex
  - lib/jido_action/exec/compensation.ex
  - lib/jido_action/exec/supervisors.ex
  - guides/execution-engine.md
decisions:
  - adr-0002
```

## Requirements

```spec-requirements
- id: jido_action.exec.instance_supervision
  statement: Jido.Exec shall route work to the global task supervisor by default and to instance-specific task supervisors when the jido option is provided.
  priority: must
  stability: stable
- id: jido_action.exec.async_mailbox_hygiene
  statement: Async await and cancel operations shall clear monitor and result messages for both current and legacy async references.
  priority: must
  stability: stable
- id: jido_action.exec.compensation_mailbox_hygiene
  statement: Compensation execution shall not leak monitor or result messages after timeout or crash handling.
  priority: must
  stability: stable
```

## Verification

```spec-verification
- kind: command
  target: MIX_ENV=test mix test test/jido_action/exec/instance_isolation_test.exs test/jido_action/exec/async_mailbox_hygiene_test.exs test/jido_action/exec/compensation_mailbox_hygiene_test.exs
  execute: true
  covers:
    - jido_action.exec.instance_supervision
    - jido_action.exec.async_mailbox_hygiene
    - jido_action.exec.compensation_mailbox_hygiene
```
