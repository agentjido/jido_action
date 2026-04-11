# Error Handling

Normalized error types and helper APIs for validation, execution, config, timeout, and internal failures.

## Intent

Describe the package-wide error surface that execution and action helpers return.

```spec-meta
id: jido_action.error_handling
kind: module
status: active
summary: Centralized error classes, concrete exceptions, direct JSON encoding, and normalization helpers for Jido action failures.
surface:
  - lib/jido_action/error.ex
  - guides/error-handling.md
  - test/jido_action/error_test.exs
decisions:
  - jido_action.spec_migration
  - jido_action.error_struct_json_encoding
```

## Requirements

```spec-requirements
- id: jido_action.error_handling.normalized_errors
  statement: Jido.Action.Error shall provide concrete exception structs and helper constructors for validation, execution, timeout, configuration, and internal errors, with normalized mapping suitable for cross-package handling.
  priority: must
  stability: stable

- id: jido_action.error_handling.direct_json_struct_fields
  statement: Jido.Action.Error shall let callers encode its concrete exception structs directly through Jason for stable top-level fields such as message, field, value, and timeout, while omitting raw `:details` values that may still contain non-JSON-safe runtime terms.
  priority: should
  stability: evolving

- id: jido_action.error_handling.transport_safe_error_maps
  statement: Jido.Action.Error.to_map/1 shall normalize action errors into maps whose `:details` payload is transport-safe recursive data for maps, structs, exceptions, tuples, and nested runtime terms without mutating the original in-process error value.
  priority: must
  stability: stable

- id: jido_action.error_handling.retryable_hints
  statement: Jido.Action.Error.retryable?/1 shall derive stable retryability hints from timeout errors, transient reason atoms, explicit retry flags, and normalized error types so downstream callers and guides can make consistent retry decisions.
  priority: should
  stability: stable
```

## Verification

```spec-verification
- kind: command
  target: mix test test/jido_action/error_test.exs
  execute: true
  covers:
    - jido_action.error_handling.normalized_errors
    - jido_action.error_handling.direct_json_struct_fields
    - jido_action.error_handling.transport_safe_error_maps
    - jido_action.error_handling.retryable_hints
```
