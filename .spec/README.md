# `.spec`

This folder is the package-local Spec Led Development layer for Jido.Action.

<!-- spec.workspace.readme_present -->

It captures package intent, core action contracts, execution behavior,
AI tool integration, and workflow composition.

## Current Subjects

- `specs/spec_system.spec.md`
- `specs/package.spec.md`
- `specs/action_contract.spec.md`
- `specs/execution_engine.spec.md`
- `specs/ai_tools.spec.md`
- `specs/workflow_plans.spec.md`

## Core Loop

1. tighten or add authored specs in `.spec/specs/`
2. update code, guides, or tests
3. run `mix spec.verify` for a fast structural pass
4. run `mix spec.check` for the stricter local gate

## Verification Strength

Starter adoption in this repo currently targets `claimed` strength.
Moving to `linked` will require requirement ids to appear in the guide,
source, or test files named by verification entries.
