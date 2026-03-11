# Jido.Action Package

High-level package contract for Jido.Action.

```spec-meta
id: jido_action.package
kind: package
status: active
summary: Package contract covering action definition, execution, AI tool conversion, and workflow composition.
surface:
  - README.md
  - lib/jido_action.ex
  - lib/jido_action/exec.ex
  - lib/jido_action/tool.ex
  - lib/jido_instruction.ex
  - lib/jido_plan.ex
```

## Requirements

```spec-requirements
- id: jido_action.package.actions
  statement: The package shall provide a validated core action behavior that lets applications define structured actions with schemas and metadata.
  priority: must
  stability: stable
- id: jido_action.package.execution
  statement: The package shall provide a reliable execution engine for running actions directly or through execution policies.
  priority: must
  stability: stable
- id: jido_action.package.ai_tools
  statement: The package shall expose AI-compatible tool conversion for actions.
  priority: must
  stability: stable
- id: jido_action.package.workflow_composition
  statement: The package shall let applications normalize instructions and compose them into dependency-aware plans.
  priority: must
  stability: stable
```

## Verification

```spec-verification
- kind: source_file
  target: .spec/specs/action_contract.spec.md
  covers:
    - jido_action.package.actions
- kind: source_file
  target: .spec/specs/execution_engine.spec.md
  covers:
    - jido_action.package.execution
- kind: source_file
  target: .spec/specs/ai_tools.spec.md
  covers:
    - jido_action.package.ai_tools
- kind: source_file
  target: .spec/specs/workflow_plans.spec.md
  covers:
    - jido_action.package.workflow_composition
```
