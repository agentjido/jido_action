# Error Handling

Normalized error types and helper APIs for validation, execution, config, timeout, and internal failures.

## Intent

Describe the package-wide error surface that execution and action helpers return.

```spec-meta
id: jido_action.error_handling
kind: module
status: active
summary: Centralized error classes, concrete exceptions, and normalization helpers for Jido action failures.
surface:
  - lib/jido_action/error.ex
  - guides/error-handling.md
  - test/jido_action/error_test.exs
decisions:
  - jido_action.spec_migration
```

## Requirements

```spec-requirements
- id: jido_action.error_handling.normalized_errors
  statement: Jido.Action.Error shall provide concrete exception structs and helper constructors for validation, execution, timeout, configuration, and internal errors, with normalized mapping suitable for cross-package handling.
  priority: must
  stability: stable
```

## Verification

```spec-verification
- kind: command
  target: mix test test/jido_action/error_test.exs
  execute: true
  covers:
    - jido_action.error_handling.normalized_errors
```
