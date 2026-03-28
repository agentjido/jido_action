# Instructions And Workflows

Instruction normalization, plan building, and workflow/action-plan execution.

## Intent

Describe the package surface for building multi-step work from actions.

```spec-meta
id: jido_action.workflow
kind: workflow
status: active
summary: Instruction normalization plus plan and workflow execution helpers built on top of Jido actions.
surface:
  - lib/jido_instruction.ex
  - lib/jido_plan.ex
  - lib/jido_tools/action_plan.ex
  - lib/jido_tools/workflow.ex
  - lib/jido_tools/workflow/execution.ex
  - guides/instructions-plans.md
  - test/jido/plan*.exs
  - test/jido_action/examples/user_registration_workflow_test.exs
  - test/jido_action/instruction_test.exs
  - test/jido_tools/action_plan_test.exs
  - test/jido_tools/workflow*.exs
decisions:
  - jido_action.spec_migration
```

## Requirements

```spec-requirements
- id: jido_action.workflow.instruction_normalization
  statement: Jido.Instruction shall normalize modules, tuples, and structs into executable instructions with shared context and execution options.
  priority: must
  stability: stable

- id: jido_action.workflow.plan_and_workflow_execution
  statement: Jido.Plan, Jido.Tools.Workflow, and Jido.Tools.ActionPlan shall model dependency-aware workflows and execute sequential, branched, parallel, and result-transforming action plans through Jido.Exec.
  priority: must
  stability: stable
```

## Verification

```spec-verification
- kind: command
  target: mix test test/jido_action/instruction_test.exs test/jido/plan_test.exs test/jido/plan_coverage_test.exs test/jido/plan_missing_dependency_test.exs
  execute: true
  covers:
    - jido_action.workflow.instruction_normalization
    - jido_action.workflow.plan_and_workflow_execution

- kind: command
  target: mix test test/jido_tools/action_plan_test.exs test/jido_tools/workflow_test.exs test/jido_tools/workflow_parallel_policy_test.exs test/jido_tools/workflow_retry_policy_test.exs test/jido_action/examples/user_registration_workflow_test.exs
  execute: true
  covers:
    - jido_action.workflow.plan_and_workflow_execution
```
