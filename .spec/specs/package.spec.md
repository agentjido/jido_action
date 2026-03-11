# Jido.Action Package

High-level package contract for Jido.Action.

## Cross-Cutting Decisions

- `.spec/decisions/adr-0001-declarative-current-truth.md`
- `.spec/decisions/adr-0003-verification-strength-policy.md`

```spec-meta
id: jido_action.package
kind: package
status: active
summary: Package contract covering action definition, schema handling, execution runtime, AI tool conversion, and workflow composition.
surface:
  - README.md
  - lib/jido_action.ex
  - lib/jido_action/application.ex
  - lib/jido_action/error.ex
  - lib/jido_action/exec.ex
  - lib/jido_action/schema.ex
  - lib/jido_action/tool.ex
  - lib/jido_action/util.ex
  - lib/jido_instruction.ex
  - lib/jido_plan.ex
decisions:
  - adr-0001
  - adr-0002
  - adr-0003
```

## Requirements

```spec-requirements
- id: jido_action.package.actions
  statement: The package shall provide a validated core action behavior that lets applications define structured actions with schemas and metadata.
  priority: must
  stability: stable
- id: jido_action.package.schemas
  statement: The package shall provide schema adapters and a JSON Schema bridge for action validation and tool projection.
  priority: must
  stability: stable
- id: jido_action.package.runtime_support
  statement: The package shall provide shared runtime errors, utility helpers, and default execution supervision for Jido.Action.
  priority: must
  stability: stable
- id: jido_action.package.execution_run_modes
  statement: The package shall provide direct, async, and closure-based execution entrypoints for running actions.
  priority: must
  stability: stable
- id: jido_action.package.execution_reliability
  statement: The package shall provide retries, timeout supervision, compensation, and runtime-default execution policy controls.
  priority: must
  stability: stable
- id: jido_action.package.execution_chains
  statement: The package shall provide dependency-ordered action chaining with interruption and async supervision support.
  priority: must
  stability: stable
- id: jido_action.package.execution_isolation
  statement: The package shall isolate instance-specific execution supervisors and keep async or compensation mailbox state from leaking into callers.
  priority: must
  stability: stable
- id: jido_action.package.execution_telemetry
  statement: The package shall expose telemetry and logging that redacts sensitive data and stays safe for large nested payloads.
  priority: must
  stability: stable
- id: jido_action.package.ai_tools
  statement: The package shall expose AI-compatible tool conversion for actions.
  priority: must
  stability: stable
- id: jido_action.package.instructions
  statement: The package shall let applications normalize instruction inputs into Jido.Instruction values.
  priority: must
  stability: stable
- id: jido_action.package.plans
  statement: The package shall let applications compose dependency-aware plans from normalized instructions.
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
  target: .spec/specs/schema_adapters.spec.md
  covers:
    - jido_action.package.schemas
- kind: source_file
  target: .spec/specs/runtime_support.spec.md
  covers:
    - jido_action.package.runtime_support
- kind: source_file
  target: .spec/specs/exec_run_modes.spec.md
  covers:
    - jido_action.package.execution_run_modes
- kind: source_file
  target: .spec/specs/exec_reliability_controls.spec.md
  covers:
    - jido_action.package.execution_reliability
- kind: source_file
  target: .spec/specs/exec_chains.spec.md
  covers:
    - jido_action.package.execution_chains
- kind: source_file
  target: .spec/specs/exec_isolation_mailbox.spec.md
  covers:
    - jido_action.package.execution_isolation
- kind: source_file
  target: .spec/specs/exec_telemetry.spec.md
  covers:
    - jido_action.package.execution_telemetry
- kind: source_file
  target: .spec/specs/ai_tools.spec.md
  covers:
    - jido_action.package.ai_tools
- kind: source_file
  target: .spec/specs/instruction_normalization.spec.md
  covers:
    - jido_action.package.instructions
- kind: source_file
  target: .spec/specs/plan_graph.spec.md
  covers:
    - jido_action.package.plans
```
