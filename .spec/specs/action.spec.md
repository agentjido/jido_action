# Jido.Action

Core action behavior for metadata, schema validation, and AI tool conversion.

## Intent

Describe the contract for defining actions with `use Jido.Action` and executing them through the tool bridge.

```spec-meta
id: jido_action.action
kind: module
status: active
summary: Action definition contract for metadata, schema-backed validation, and tool conversion.
surface:
  - lib/jido_action.ex
  - lib/jido_action/tool.ex
  - lib/jido_action/util.ex
  - guides/actions-guide.md
  - guides/getting-started.md
  - guides/your-second-action.md
  - test/jido_action/action_test.exs
  - test/jido_action/on_after_run_test.exs
  - test/jido_action/exec_tool_test.exs
  - test/jido_action/util_test.exs
decisions:
  - jido_action.spec_migration
  - jido_action.action_effect_boundary_docs
```

## Requirements

```spec-requirements
- id: jido_action.action.metadata_contract
  statement: use Jido.Action shall define named action modules that expose action metadata, declared schemas, JSON-friendly metadata accessors, and overridable lifecycle callbacks whose contracts are defined by the Jido.Action behaviour callbacks.
  priority: must
  stability: stable

- id: jido_action.action.schema_validation
  statement: Actions shall validate declared input and output schemas while preserving unspecified fields so composed actions can pass through extra data and lifecycle callbacks can adjust results.
  priority: must
  stability: stable

- id: jido_action.action.tool_bridge
  statement: Actions shall convert declared schemas into AI tool parameter schemas and coerce known tool inputs without discarding unknown keys.
  priority: should
  stability: evolving

- id: jido_action.action.tool_execution_json_contract
  statement: Jido.Action.Tool.execute_action/3 shall preserve the legacy `{:ok, json}` and `{:error, json}` contract while emitting sanitized success payloads and binary error payloads even when raw failure inspection is unsafe.
  priority: should
  stability: evolving

- id: jido_action.action.log_level_resolution
  statement: Jido.Action.Util shall resolve execution log levels from per-call options and package configuration, warn on invalid configured or call-site values, and fall back to stable defaults so action and tool execution keeps predictable logging behavior.
  priority: should
  stability: evolving

- id: jido_action.action.effect_boundary_guidance
  statement: The Jido.Action moduledoc and Actions guide shall state that an action's `run/2` may be pure or effectful, that inline I/O is acceptable when the step needs the result immediately, and that `jido` keeps its purity guarantee at the agent or strategy `cmd/2` boundary rather than on every invoked action.
  priority: should
  stability: evolving
```

## Verification

```spec-verification
- kind: command
  target: mix test test/jido_action/action_test.exs test/jido_action/on_after_run_test.exs test/jido_action/exec_tool_test.exs test/jido_action/util_test.exs
  execute: true
  covers:
    - jido_action.action.metadata_contract
    - jido_action.action.schema_validation
    - jido_action.action.tool_bridge
    - jido_action.action.tool_execution_json_contract
    - jido_action.action.log_level_resolution

- kind: source_file
  target: lib/jido_action.ex
  covers:
    - jido_action.action.effect_boundary_guidance

- kind: guide_file
  target: guides/actions-guide.md
  covers:
    - jido_action.action.effect_boundary_guidance
```
