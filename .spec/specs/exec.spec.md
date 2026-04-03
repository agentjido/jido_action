# Jido.Exec

Execution engine contracts for synchronous, asynchronous, and policy-aware action runs.

## Intent

Describe the execution semantics that sit between authored actions and runtime policy.

```spec-meta
id: jido_action.exec
kind: workflow
status: active
summary: Execution engine for action normalization, retries, timeouts, cancellation, compensation, telemetry, and instance-scoped supervision.
surface:
  - lib/jido_action/application.ex
  - lib/jido_action/runtime.ex
  - lib/jido_action/exec.ex
  - lib/jido_action/exec/*.ex
  - guides/configuration.md
  - guides/execution-engine.md
  - guides/testing.md
  - test/jido_action/exec*_test.exs
  - test/jido_action/exec/*.exs
decisions:
  - jido_action.spec_migration
  - jido_action.cross_subject_ci_stabilization
```

## Requirements

```spec-requirements
- id: jido_action.exec.sync_async_engine
  statement: Jido.Exec shall normalize params and context, execute actions synchronously or asynchronously, and preserve action metadata in the runtime context it passes to actions.
  priority: must
  stability: stable

- id: jido_action.exec.reliability_controls
  statement: The execution engine shall apply retries, timeout handling, cancellation cleanup, compensation, telemetry, and instance-scoped supervisor/config behavior where those policies are configured, including routing timeout cleanup checks through isolated supervisors when verification needs to avoid ambient shared tasks.
  priority: must
  stability: stable

- id: jido_action.exec.error_result_normalization
  statement: When an action returns `{:error, reason}` without an exception struct, Jido.Exec shall return an `ExecutionFailureError` with a string message and preserve structured map details for downstream handling.
  priority: must
  stability: stable
```

## Verification

```spec-verification
- kind: command
  target: mix test test/jido_action/exec_run_test.exs test/jido_action/exec_async_test.exs test/jido_action/exec_task_test.exs test/jido_action/exec_execute_test.exs test/jido_action/exec_integration_test.exs test/jido_action/exec_config_test.exs test/jido_action/exec_timeout_task_supervisor_test.exs test/jido_action/exec_retry_policy_test.exs test/jido_action/exec_return_shape_test.exs test/jido_action/exec_do_run_test.exs test/jido_action/exec_compensate_test.exs test/jido_action/exec_output_validation_test.exs test/jido_action/exec_final_coverage_test.exs test/jido_action/exec_misc_coverage_test.exs test/jido_action/exec_coverage_test.exs
  execute: true
  covers:
    - jido_action.exec.sync_async_engine
    - jido_action.exec.reliability_controls
    - jido_action.exec.error_result_normalization

- kind: command
  target: mix test test/jido_action/exec/async_mailbox_hygiene_test.exs test/jido_action/exec/chain_test.exs test/jido_action/exec/chain_interrupt_test.exs test/jido_action/exec/chain_supervision_test.exs test/jido_action/exec/closure_test.exs test/jido_action/exec/compensation_mailbox_hygiene_test.exs test/jido_action/exec/instance_isolation_test.exs test/jido_action/exec/telemetry_sanitization_test.exs
  execute: true
  covers:
    - jido_action.exec.sync_async_engine
    - jido_action.exec.reliability_controls
```
