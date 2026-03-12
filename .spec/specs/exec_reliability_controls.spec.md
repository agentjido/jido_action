# Jido.Exec Reliability Controls

Supports package requirement `jido_action.package.execution_reliability`.

## Intent

Define how Jido.Exec applies retry policy, timeout supervision, compensation,
and runtime default policy resolution.

```spec-meta
id: jido_action.exec.reliability_controls
kind: workflow
status: active
summary: Retry, timeout, compensation, and runtime-default execution policy for Jido.Exec.
surface:
  - lib/jido_action/exec.ex
  - lib/jido_action/exec/retry.ex
  - lib/jido_action/exec/compensation.ex
  - guides/execution-engine.md
decisions:
  - adr-0002
```

## Requirements

```spec-requirements
- id: jido_action.exec.retry_policies
  statement: Jido.Exec shall retry recoverable execution failures while suppressing retries for validation and configuration errors or explicit no-retry hints.
  priority: must
  stability: stable
- id: jido_action.exec.timeout_supervision
  statement: Jido.Exec shall run timeout-bound actions under supervised tasks, return structured timeout or task-exit errors, and clean up timed-out child processes.
  priority: must
  stability: stable
- id: jido_action.exec.compensation_flow
  statement: Jido.Exec shall run action compensation after terminal failures, preserve original failure context, and report compensation timeout or crash details.
  priority: must
  stability: stable
- id: jido_action.exec.runtime_default_policies
  statement: Jido.Exec shall resolve timeout, retry, and backoff defaults from runtime config when explicit opts are absent and fall back safely when config values are invalid.
  priority: must
  stability: stable
```

## Verification

```spec-verification
- kind: command
  target: MIX_ENV=test mix test test/jido_action/exec_retry_policy_test.exs test/jido_action/exec_timeout_task_supervisor_test.exs test/jido_action/exec_compensate_test.exs test/jido_action/exec_config_test.exs test/jido_action/exec_coverage_test.exs
  execute: true
  covers:
    - jido_action.exec.retry_policies
    - jido_action.exec.timeout_supervision
    - jido_action.exec.compensation_flow
    - jido_action.exec.runtime_default_policies
```
