# Jido.Action.Sanitizer

Shared structural sanitization for transport-safe package boundaries and telemetry-safe runtime values.

## Intent

Describe the shared sanitizer contract reused by normalized errors, tool execution payloads, and execution telemetry.

```spec-meta
id: jido_action.sanitizer
kind: module
status: active
summary: Shared transport and telemetry sanitization for arbitrary runtime terms used across Jido Action boundaries.
surface:
  - lib/jido_action/sanitizer.ex
  - test/jido_action/sanitizer_test.exs
decisions:
  - jido_action.spec_migration
```

## Requirements

```spec-requirements
- id: jido_action.sanitizer.transport_profile
  statement: Jido.Action.Sanitizer shall recursively convert arbitrary runtime terms into Jason-safe plain data for transport boundaries, preserving struct and exception provenance as explicit markers and avoiding crashes on inspect-hostile or unsupported leaves.
  priority: must
  stability: stable

- id: jido_action.sanitizer.telemetry_profile
  statement: Jido.Action.Sanitizer shall provide a telemetry profile that preserves execution telemetry semantics for redaction, truncation, tuple handling, inspect-safe summaries, and bounded traversal of nested runtime terms.
  priority: must
  stability: stable
```

## Verification

```spec-verification
- kind: command
  target: mix test test/jido_action/sanitizer_test.exs
  execute: true
  covers:
    - jido_action.sanitizer.transport_profile
    - jido_action.sanitizer.telemetry_profile

- kind: command
  target: mix test test/jido_action/exec/telemetry_sanitization_test.exs
  execute: true
  covers:
    - jido_action.sanitizer.telemetry_profile
```
