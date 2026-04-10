---
id: jido_action.error_struct_json_encoding
status: accepted
date: 2026-04-10
affects:
  - jido_action.error_handling
  - jido_action.package
---

# Keep direct error JSON encoding shallow and preserve `to_map/1` as the full transport boundary

## Context

`Jido.Action.Error` already owned the package's transport-safe error-map conversion through
`to_map/1`, but callers and tests also treat the concrete exception structs as part of the public
failure surface. This branch adds direct `Jason.encode/1` support for the concrete error structs.

Those structs still carry a `:details` field that may include stacktraces, tuples, nested
exceptions, or other runtime terms that are not safe to dump directly through Jason. That means the
branch changes both the error-handling subject and the package-level execution failure surface in a
durable way.

## Decision

The package supports two JSON-facing error representations with different responsibilities:

- direct `Jason.encode/1` on concrete `Jido.Action.Error.*Error` structs is supported for stable
  top-level fields such as `message`, `field`, `value`, and `timeout`
- derived struct encoding shall omit raw `:details`
- callers that need a full structured payload shall use `Jido.Action.Error.to_map/1`, which
  remains the path that sanitizes nested runtime terms into transport-safe data
- shared error tests may prove both surfaces because they describe the same durable failure
  contract from different access paths

## Consequences

- Direct JSON encoding stays convenient for shallow transport cases that only need the stable
  top-level fields.
- The richer `:details` contract remains explicit and sanitized through `to_map/1` instead of
  relying on Jason protocol implementations for arbitrary runtime terms.
- Future changes that add or remove directly encoded fields should update both impacted subject
  specs and this ADR together.
