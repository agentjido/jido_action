# Workflow Plans

Supports package requirement `jido_action.package.workflow_composition`.

## Intent

Define how Jido.Action normalizes instructions and composes them into
dependency-aware plans.

```spec-meta
id: jido_action.workflow_plans
kind: workflow
status: active
summary: Instruction normalization and plan composition contract for Jido.Action workflows.
surface:
  - lib/jido_instruction.ex
  - lib/jido_plan.ex
  - guides/instructions-plans.md
```

## Requirements

```spec-requirements
- id: jido_action.workflow.instruction_normalization
  statement: The package shall normalize action modules, tuples, and structs into Jido.Instruction values with shared params, context, and opts.
  priority: must
  stability: stable
- id: jido_action.workflow.plan_dependencies
  statement: The package shall build plans with named steps and dependency edges that can be normalized as DAG workflows.
  priority: must
  stability: stable
```

## Verification

```spec-verification
- kind: command
  target: MIX_ENV=test mix test test/jido_action/instruction_test.exs test/jido/plan_test.exs test/jido/plan_missing_dependency_test.exs
  execute: true
  covers:
    - jido_action.workflow.instruction_normalization
    - jido_action.workflow.plan_dependencies
```
