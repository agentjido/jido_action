# Jido.Exec Telemetry

Supports package requirement `jido_action.package.execution_telemetry`.

## Intent

Define how Jido.Exec emits telemetry and logs execution payloads without leaking
sensitive or overly large nested data.

```spec-meta
id: jido_action.exec.telemetry
kind: workflow
status: active
summary: Telemetry mode selection and payload sanitization for Jido.Exec.
surface:
  - lib/jido_action/exec.ex
  - lib/jido_action/exec/telemetry.ex
  - guides/execution-engine.md
decisions:
  - adr-0002
```

## Requirements

```spec-requirements
- id: jido_action.exec.telemetry_modes
  statement: Jido.Exec shall support full, minimal, and silent telemetry modes for runtime execution.
  priority: must
  stability: stable
- id: jido_action.exec.telemetry_sanitization
  statement: Execution telemetry and log payloads shall redact sensitive fields, truncate large data, and stay inspect-safe for nested structs.
  priority: must
  stability: stable
```

## Verification

```spec-verification
- kind: command
  target: MIX_ENV=test mix test test/jido_action/exec_do_run_test.exs test/jido_action/exec/telemetry_sanitization_test.exs test/jido_action/exec_compensate_test.exs
  execute: true
  covers:
    - jido_action.exec.telemetry_modes
    - jido_action.exec.telemetry_sanitization
```
