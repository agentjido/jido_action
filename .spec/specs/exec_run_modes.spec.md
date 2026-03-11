# Jido.Exec Run Modes

Supports package requirement `jido_action.package.execution_run_modes`.

## Intent

Define how Jido.Exec exposes sync, async, and closure-based execution entrypoints
while enforcing supported action return shapes and output validation.

```spec-meta
id: jido_action.exec.run_modes
kind: workflow
status: active
summary: Direct, async, and closure-based execution entrypoints for Jido.Exec.
surface:
  - lib/jido_action/exec.ex
  - lib/jido_action/exec/async.ex
  - lib/jido_action/exec/closure.ex
  - lib/jido_action/exec/validator.ex
  - guides/execution-engine.md
```

## Requirements

```spec-requirements
- id: jido_action.exec.sync_async_entrypoints
  statement: Jido.Exec shall run actions synchronously or asynchronously and enforce async ownership on await and cancel operations.
  priority: must
  stability: stable
- id: jido_action.exec.closure_helpers
  statement: Jido.Exec.Closure shall capture action, context, and execution opts into reusable sync and async callables over later params.
  priority: must
  stability: stable
- id: jido_action.exec.return_contract
  statement: Execution entrypoints shall accept only supported ok and error tuple shapes, preserve directives, and validate declared output schemas on successful results.
  priority: must
  stability: stable
```

## Verification

```spec-verification
- kind: command
  target: MIX_ENV=test mix test test/jido_action/exec_run_test.exs test/jido_action/exec_async_test.exs test/jido_action/exec_execute_test.exs test/jido_action/exec_return_shape_test.exs test/jido_action/exec_output_validation_test.exs test/jido_action/exec/closure_test.exs
  execute: true
  covers:
    - jido_action.exec.sync_async_entrypoints
    - jido_action.exec.closure_helpers
    - jido_action.exec.return_contract
```
