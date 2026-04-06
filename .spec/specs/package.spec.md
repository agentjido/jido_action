# Jido Action Package

Composable, validated actions for Elixir applications with execution, workflow, and AI tool support.

## Intent

Define the package-level contract that the repository documents and tests today.

```spec-meta
id: jido_action.package
kind: package
status: active
summary: Package-level contract for action definition, execution, workflow normalization, planning, AI tool integration, publishable dependency packaging, and legacy-safe execution logging defaults.
surface:
  - .github/workflows/specs.yml
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
  - jido_action.cross_subject_ci_stabilization
  - jido_action.action_effect_boundary_docs
  - jido_action.execution_logging_hygiene
```

## Requirements

```spec-requirements
- id: jido_action.package.core_surface
  statement: The package shall provide Jido.Action, Jido.Exec, Jido.Instruction, Jido.Plan, and Jido.Action.Tool as the core surface for defining actions, executing them, normalizing workflow instructions, planning DAG workflows, and exposing AI-compatible tool definitions, with action behaviour callbacks serving as the stable type contract for generated action modules and tool execution preserving the legacy JSON string contract.
  priority: must
  stability: stable

- id: jido_action.package.execution_failure_surface
  statement: The package-level execution surface shall expose runtime failures as normalized exception structs with string messages and structured, transport-safe details suitable for downstream handling and JSON encoding.
  priority: should
  stability: evolving

- id: jido_action.package.execution_logging_defaults
  statement: The package-level execution surface shall keep routine execution traces quiet by default, require explicit `:log_level` opt-in for debug traces, and keep runtime inspection sanitization within the owning execution boundary instead of a package-wide logging facade.
  priority: should
  stability: evolving

- id: jido_action.package.readme_onboarding
  statement: The README shall document installation plus quick-start usage for action definition, execution, workflow normalization, and AI tool integration, and it shall explicitly explain that an action's `run/2` may perform side effects while `jido` keeps its purity guarantee at the agent or strategy `cmd/2` boundary.
  priority: should
  stability: evolving

- id: jido_action.package.publishable_dependency_graph
  statement: The package manifest shall resolve on Hex with a publishable dependency graph for workflow planning, using the direct `multigraph` package instead of aliasing a package into the `:libgraph` OTP app slot.
  priority: should
  stability: evolving

- id: jido_action.package.spec_pr_gate
  statement: Pull request CI shall run `mix spec.check` against the pull request base branch so Spec Led current truth and proof stay enforced in review.
  priority: should
  stability: evolving

- id: jido_action.package.contributor_spec_workflow
  statement: CONTRIBUTING.md shall document the Spec Led contribution loop, including when to update `.spec/specs/`, when to revise `.spec/decisions/`, and the pre-PR `mix spec.check --base <base-ref>` step.
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

- kind: command
  target: mix test test/jido_action/exec_return_shape_test.exs test/jido_action/error_test.exs
  execute: true
  covers:
    - jido_action.package.execution_failure_surface

- kind: command
  target: mix test test/jido_action/exec_integration_test.exs test/jido_action/exec/telemetry_sanitization_test.exs test/jido_action/exec/chain_test.exs
  execute: true
  covers:
    - jido_action.package.execution_logging_defaults

- kind: readme_file
  target: README.md
  covers:
    - jido_action.package.readme_onboarding

- kind: command
  target: MIX_ENV=prod mix deps.get
  execute: true
  covers:
    - jido_action.package.publishable_dependency_graph

- kind: workflow_file
  target: .github/workflows/specs.yml
  covers:
    - jido_action.package.spec_pr_gate

- kind: file
  target: CONTRIBUTING.md
  covers:
    - jido_action.package.contributor_spec_workflow
```
