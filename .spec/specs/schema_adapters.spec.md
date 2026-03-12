# Jido.Action Schema Adapters

Supports package requirement `jido_action.package.schemas`.

## Intent

Define how Jido.Action.Schema recognizes supported schema forms, emits JSON
Schema, and bridges supported JSON Schema subsets back into Zoi.

```spec-meta
id: jido_action.schema_adapters
kind: contract
status: active
summary: Schema type detection, JSON Schema projection, and JSON Schema bridge behavior.
surface:
  - lib/jido_action/schema.ex
  - lib/jido_action/schema/json_schema_bridge.ex
  - guides/schemas-validation.md
  - guides/ai-integration.md
```

## Requirements

```spec-requirements
- id: jido_action.schema.adapter_contract
  statement: Jido.Action.Schema shall recognize empty, NimbleOptions, Zoi, and JSON Schema map inputs, expose known keys, and validate config schemas without creating unsafe atoms.
  priority: must
  stability: stable
- id: jido_action.schema.json_projection
  statement: Jido.Action.Schema shall emit JSON Schema for supported schema inputs and apply strict additionalProperties controls when requested.
  priority: must
  stability: stable
- id: jido_action.schema.json_bridge
  statement: Jido.Action.Schema.JsonSchemaBridge shall translate the supported JSON Schema subset into Zoi schemas, preserve legacy param conversion behavior, and fall back cleanly on unsupported constructs.
  priority: must
  stability: stable
```

## Verification

```spec-verification
- kind: command
  target: MIX_ENV=test mix test test/jido_action/schema_json_test.exs test/jido_action/json_schema_map_test.exs test/jido_action/json_schema_bridge_test.exs test/jido_action/zoi_schema_test.exs
  execute: true
  covers:
    - jido_action.schema.adapter_contract
    - jido_action.schema.json_projection
    - jido_action.schema.json_bridge
```
