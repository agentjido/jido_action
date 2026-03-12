# `.spec`

This folder is the package-local Spec Led Development layer for Jido.Action.

<!-- spec.workspace.readme_present -->

It captures package intent, core action contracts, execution behavior,
schema handling, AI tool integration, workflow composition, and the
cross-cutting decisions that govern this workspace.

## Workspace Files

- `README.md`
- `AGENTS.md`
- `decisions/README.md`
- `decisions/*.md`
- `specs/*.spec.md`
- `state.json`

## ADR Usage

This workspace is declarative and current-state only.

- update current-truth subject specs to match merged package behavior
- use Git branches, commits, and pull requests as the time dimension
- add an ADR only for a durable cross-cutting decision that should guide
  multiple future edits

## Current Subjects

- `specs/spec_system.spec.md`
- `specs/package.spec.md`
- `specs/action_contract.spec.md`
- `specs/exec_run_modes.spec.md`
- `specs/exec_reliability_controls.spec.md`
- `specs/exec_chains.spec.md`
- `specs/exec_isolation_mailbox.spec.md`
- `specs/exec_telemetry.spec.md`
- `specs/schema_adapters.spec.md`
- `specs/runtime_support.spec.md`
- `specs/ai_tools.spec.md`
- `specs/instruction_normalization.spec.md`
- `specs/plan_graph.spec.md`

## Current ADRs

- `decisions/adr-0001-declarative-current-truth.md`
- `decisions/adr-0002-jido-exec-subject-decomposition.md`
- `decisions/adr-0003-verification-strength-policy.md`

## Core Loop

1. clarify the current behavior that should be true after merge
2. decide whether the change needs a cross-cutting ADR or only subject-spec updates
3. tighten or add authored specs in `.spec/specs/`
4. update code, guides, or tests
5. run `mix spec.verify --debug` for a fast structural pass
6. run `mix spec.check` for the stricter local gate
7. run `mix spec.diffcheck` when code, docs, or tests changed
8. use `mix spec.report` when you want a coverage and weak-spot summary

## Verification Strength

This repo prefers targeted command verifications for behavioral proof.
Workspace files can use file-backed verification because they are stable
annotation targets. Runtime source and tests should usually aim for
executed proof through the smallest focused command slice.
