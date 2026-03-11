# AI Tools

Supports package requirement `jido_action.package.ai_tools`.

## Intent

Define how Jido.Action exposes actions as AI-callable tools with schema
projection and execution through the runtime.

```spec-meta
id: jido_action.ai_tools
kind: contract
status: active
summary: AI tool conversion and execution bridge for Jido.Action modules.
surface:
  - lib/jido_action/tool.ex
  - guides/ai-integration.md
  - guides/tools-reference.md
```

## Requirements

```spec-requirements
- id: jido_action.ai.tool_projection
  statement: Actions shall expose tool definitions with JSON-schema parameter descriptions for AI callers.
  priority: must
  stability: stable
- id: jido_action.ai.tool_execution
  statement: The tool bridge shall coerce incoming params and run actions through Jido.Exec, returning JSON-safe results or errors.
  priority: must
  stability: stable
```

## Verification

```spec-verification
- kind: command
  target: MIX_ENV=test mix test test/jido_action/json_schema_bridge_test.exs test/jido_action/exec_tool_test.exs
  execute: true
  covers:
    - jido_action.ai.tool_projection
    - jido_action.ai.tool_execution
```
