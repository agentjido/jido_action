# Jido.Plan

Supports package requirement `jido_action.package.plans`.

## Intent

Define how Jido.Plan builds dependency-aware DAG workflows from
instructions and plan shorthands.

```spec-meta
id: jido_action.plan_graph
kind: workflow
status: active
summary: Builder, dependency validation, and execution phase contract for Jido.Plan.
surface:
  - lib/jido_plan.ex
  - guides/instructions-plans.md
```

## Requirements

```spec-requirements
- id: jido_action.plan.builder_contract
  statement: Jido.Plan shall build named steps from action modules and instruction shorthands while carrying plan context into each normalized instruction.
  priority: must
  stability: stable
- id: jido_action.plan.dependency_validation
  statement: Jido.Plan normalization shall reject undefined or cyclic dependencies before execution.
  priority: must
  stability: stable
- id: jido_action.plan.execution_phases
  statement: Jido.Plan.execution_phases shall derive topological execution phases from the normalized dependency graph.
  priority: must
  stability: stable
```

## Scenarios

```spec-scenarios
- id: jido_action.plan.parallel_fan_out
  given:
    - a plan has multiple independent steps followed by a merge step
  when:
    - execution phases are derived
  then:
    - the independent steps share a phase
    - the merge step is scheduled after them
  covers:
    - jido_action.plan.execution_phases
- id: jido_action.plan.missing_dependency
  given:
    - a plan references a dependency that is not defined as a step
  when:
    - the plan normalizes
  then:
    - normalization returns a validation error
  covers:
    - jido_action.plan.dependency_validation
```

## Verification

```spec-verification
- kind: command
  target: MIX_ENV=test mix test test/jido/plan_test.exs test/jido/plan_coverage_test.exs test/jido/plan_missing_dependency_test.exs
  execute: true
  covers:
    - jido_action.plan.builder_contract
    - jido_action.plan.dependency_validation
    - jido_action.plan.execution_phases
```
