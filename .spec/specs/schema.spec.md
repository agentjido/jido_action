# Schema Handling

Unified schema validation and JSON Schema translation for actions and tools.

## Intent

Describe how the package treats NimbleOptions, Zoi, and JSON Schema maps as first-class schema inputs.

```spec-meta
id: jido_action.schema
kind: module
status: active
summary: Unified schema adapter for validation, key discovery, JSON Schema export, bridging, and atom-safe tool input handling.
surface:
  - lib/jido_action/schema.ex
  - lib/jido_action/schema/json_schema_bridge.ex
  - guides/schemas-validation.md
  - test/jido_action/atom_safety_test.exs
  - test/jido_action/json_schema_bridge_test.exs
  - test/jido_action/json_schema_map_test.exs
  - test/jido_action/schema_json_test.exs
  - test/jido_action/zoi_schema_test.exs
decisions:
  - jido_action.spec_migration
```

## Requirements

```spec-requirements
- id: jido_action.schema.unified_validation
  statement: The package shall provide one schema adapter that accepts NimbleOptions, Zoi, empty schemas, and JSON Schema maps for validation and key introspection.
  priority: must
  stability: stable

- id: jido_action.schema.safe_tool_translation
  statement: Schema handling shall translate declared schemas into tool-friendly JSON Schema, bridge supported JSON Schema subsets to Zoi when possible, and avoid unsafe atom creation when processing tool input.
  priority: must
  stability: stable

- id: jido_action.schema.nimble_json_schema_annotations
  statement: NimbleOptions schema export shall preserve required keys, infer JSON-friendly primitive and enum types, and emit per-property descriptions with a fallback placeholder when the schema author does not provide one.
  priority: should
  stability: stable
```

## Verification

```spec-verification
- kind: command
  target: mix test test/jido_action/zoi_schema_test.exs test/jido_action/schema_json_test.exs
  execute: true
  covers:
    - jido_action.schema.unified_validation
    - jido_action.schema.safe_tool_translation
    - jido_action.schema.nimble_json_schema_annotations

- kind: command
  target: mix test test/jido_action/json_schema_map_test.exs test/jido_action/json_schema_bridge_test.exs test/jido_action/atom_safety_test.exs
  execute: true
  covers:
    - jido_action.schema.unified_validation
    - jido_action.schema.safe_tool_translation
```
