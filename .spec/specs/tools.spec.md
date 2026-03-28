# Built-In Tools

Reusable action modules for common utility, IO, request, and Lua-backed work.

## Intent

Describe the tool modules the package ships for direct use and AI-facing composition.

```spec-meta
id: jido_action.tools
kind: module
status: active
summary: Built-in Jido tool actions for basic utilities, arithmetic, files, HTTP requests, and Lua execution.
surface:
  - lib/jido_tools/arithmetic.ex
  - lib/jido_tools/basic.ex
  - lib/jido_tools/files.ex
  - lib/jido_tools/lua_eval.ex
  - lib/jido_tools/req.ex
  - guides/ai-integration.md
  - guides/security.md
  - guides/tools-reference.md
  - test/jido_tools/arithmetic_test.exs
  - test/jido_tools/basic_test.exs
  - test/jido_tools/deadline_propagation_test.exs
  - test/jido_tools/files_test.exs
  - test/jido_tools/lua_eval_supervision_test.exs
  - test/jido_tools/lua_eval_test.exs
  - test/jido_tools/req_test.exs
decisions:
  - jido_action.spec_migration
```

## Requirements

```spec-requirements
- id: jido_action.tools.builtin_actions
  statement: The package shall ship reusable tool actions for arithmetic, basic utility operations, filesystem access, HTTP requests, and Lua evaluation.
  priority: must
  stability: stable

- id: jido_action.tools.policy_integration
  statement: Built-in tool actions shall cooperate with execution-policy concerns such as deadline propagation and Lua supervision where the tests exercise those boundaries.
  priority: should
  stability: evolving
```

## Verification

```spec-verification
- kind: command
  target: mix test test/jido_tools/arithmetic_test.exs test/jido_tools/basic_test.exs test/jido_tools/files_test.exs test/jido_tools/req_test.exs test/jido_tools/lua_eval_test.exs test/jido_tools/lua_eval_supervision_test.exs test/jido_tools/deadline_propagation_test.exs
  execute: true
  covers:
    - jido_action.tools.builtin_actions
    - jido_action.tools.policy_integration
```
