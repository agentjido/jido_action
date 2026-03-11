# Execution Engine

Supports package requirement `jido_action.package.execution`.

## Intent

Define the contract for running actions through Jido.Exec with sync,
async, timeout, retry, compensation, and telemetry behavior.

```spec-meta
id: jido_action.execution_engine
kind: workflow
status: active
summary: Execution engine contract for direct, async, and policy-driven action runs.
surface:
  - lib/jido_action/exec.ex
  - lib/jido_action/exec/*.ex
  - guides/execution-engine.md
```

## Requirements

```spec-requirements
- id: jido_action.exec.run_modes
  statement: Jido.Exec shall run actions synchronously or asynchronously with normalized params and context.
  priority: must
  stability: stable
- id: jido_action.exec.reliability_controls
  statement: Jido.Exec shall provide retries, timeouts, cancellation, compensation, and telemetry for policy-driven execution.
  priority: must
  stability: stable
```

## Verification

```spec-verification
- kind: command
  target: MIX_ENV=test mix test test/jido_action/exec_run_test.exs test/jido_action/exec_async_test.exs test/jido_action/exec_retry_policy_test.exs test/jido_action/exec_timeout_task_supervisor_test.exs test/jido_action/exec_compensate_test.exs
  execute: true
  covers:
    - jido_action.exec.run_modes
    - jido_action.exec.reliability_controls
```
