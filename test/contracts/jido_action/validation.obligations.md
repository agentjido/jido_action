---
modules: [Jido.Action.Validation]
---
# Shared schema validation obligations

## Purpose

Check the shared validation used by Actions and Flows. The public API remains
their validators and schema configuration. These obligations refine `ACT-001`
and `ACT-003` and retain tests for the internal validation rule.

### jido_action.validation.I1 — Validation retains the schema's data and shape rules
- **scope:** `Jido.Action.Validation.open_validate/3`, `Jido.Action.Validation.open_validate_preserving_shape/3`
- **must:** Validate whole values, maps and structs with their declared schemas. Keep refinements and coercion. The normal mode projects root structs to maps; the shape-preserving mode retains validated structs. Empty schemas pass data through. Fieldless struct schemas remain valid.
- **kind:** functional
- **status:** active

### jido_action.validation.I2 — Root and nested unknown-key policies remain distinct
- **scope:** `Jido.Action.Validation.open_validate/3`, `Jido.Action.Validation.open_validate_preserving_shape/3`
- **must:** Preserve unknown keys at direct object and struct roots when the default strip policy applies. Honor explicit strict and typed preservation policies. Nested and wrapped schemas, collections, combinations and map sets retain Zoi's declared policy rather than receiving an implicit root policy.
- **kind:** functional
- **status:** active

### jido_action.validation.I3 — Schema failures retain structured public errors
- **scope:** `Jido.Action.Validation.open_validate/3`, `Jido.Action.Validation.open_validate_preserving_shape/3`
- **must:** Return InvalidInputError for unsupported schemas and parse failures, with the complete parse errors and supplied context details. Contain raised, thrown and exited schema failures and report their kind and reason without executing later work.
- **kind:** functional
- **status:** active

### jido_action.validation.I4 — Schema classification reflects supported map containers
- **scope:** `Jido.Action.Validation.zoi_schema?/1`, `Jido.Action.Validation.map_schema?/1`
- **must:** Recognize supported Zoi schemas and map-compatible containers, including literal maps, lazy schemas, unions, intersections and codecs. Reject unsupported values and scalar-only containers. Defaults do not make a scalar schema map-compatible.
- **kind:** functional
- **status:** active
