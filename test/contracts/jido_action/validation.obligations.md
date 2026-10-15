---
modules: [Jido.Action.Validation]
---
# Shared schema validation obligations

## Purpose

Check the shared validation used by Actions and Flows. The public API remains
their validators and schema configuration. These obligations refine `ACT-001`
and `ACT-003` and retain tests for the internal validation rule.

### jido_action.validation.I1 — Validation retains the schema's data and shape rules
- **scope:** `Jido.Action.validate_params/1`, `Jido.Action.validate_output/1`, `Jido.Flow.validate_params/1`, `Jido.Flow.validate_output/1`
- **must:** Apply declared schemas at Action and Flow input/output boundaries. Keep refinements, defaults, coercion, and transforms; project normal root struct results to maps. Empty schemas still require map-shaped boundary values. Fieldless struct schemas remain valid. Accept only supported schema categories at public map boundaries. Internal scalar, lazy-schema, and shape-preserving helper cases stay implementation tests; they do not imply support in compiled Action or Flow configuration.
- **kind:** functional
- **status:** active

### jido_action.validation.I2 — Root and nested unknown-key policies remain distinct
- **scope:** `Jido.Action.validate_params/1`, `Jido.Action.validate_output/1`, `Jido.Flow.validate_params/1`, `Jido.Flow.validate_output/1`
- **must:** Preserve unknown keys at direct object and struct roots when the default strip policy applies. Honor explicit strict and typed preservation policies. Nested and wrapped schemas, collections, combinations and map sets retain Zoi's declared policy rather than receiving an implicit root policy.
- **kind:** functional
- **status:** active

### jido_action.validation.I3 — Schema failures retain structured public errors
- **scope:** `Jido.Action.validate_params/1`, `Jido.Action.validate_output/1`, `Jido.Flow.validate_params/1`, `Jido.Flow.validate_output/1`
- **must:** Return InvalidInputError for unsupported schemas and parse failures, with parse errors and boundary context details. At Exec, contain schema and custom-validator failures with documented types, phases, reasons, and paths without executing later work. Direct validator calls do not provide all Exec error containment.
- **kind:** functional
- **status:** active
