# Jido Action Package

Composable, validated actions for Elixir applications with execution, workflow, and AI tool support.

## Intent

Define the package-level contract that the repository documents and tests today.

```spec-meta
id: jido_action.package
kind: package
status: active
summary: Package-level contract for action definition, execution, workflow normalization, planning, and AI tool integration.
surface:
  - CHANGELOG.md
  - CONTRIBUTING.md
  - mix.exs
  - README.md
  - test/test_helper.exs
  - test/support/*.ex
  - usage-rules.md
  - lib/jido_action.ex
  - lib/jido_action/exec.ex
  - lib/jido_action/tool.ex
  - lib/jido_instruction.ex
  - lib/jido_plan.ex
decisions:
  - jido_action.spec_migration
```

## Requirements

```spec-requirements
- id: jido_action.package.core_surface
  statement: The package shall provide Jido.Action, Jido.Exec, Jido.Instruction, Jido.Plan, and Jido.Action.Tool as the core surface for defining actions, executing them, normalizing workflow instructions, planning DAG workflows, and exposing AI-compatible tool definitions.
  priority: must
  stability: stable

- id: jido_action.package.readme_onboarding
  statement: The README shall document installation plus quick-start usage for action definition, execution, workflow normalization, and AI tool integration.
  priority: should
  stability: evolving
```

## Verification

```spec-verification
- kind: command
  target: mix test test/jido_action/action_test.exs test/jido_action/instruction_test.exs test/jido/plan_test.exs test/jido_action/exec_tool_test.exs
  execute: true
  covers:
    - jido_action.package.core_surface

- kind: readme_file
  target: README.md
  covers:
    - jido_action.package.readme_onboarding
```
