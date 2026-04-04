# Scaffolding And Examples

Repository scaffolding tasks, examples, and maintainer-facing support guides.

## Intent

Describe the package support surface that helps users install, generate, and maintain Jido.Action projects.

```spec-meta
id: jido_action.scaffolding
kind: package
status: active
summary: Igniter-powered install/generator tasks, the bundled Zoi example, and maintainer-facing support docs.
surface:
  - lib/examples/zoi_example.ex
  - lib/mix/tasks/jido_action.gen.action.ex
  - lib/mix/tasks/jido_action.gen.workflow.ex
  - lib/mix/tasks/jido_action.install.ex
  - guides/faq.md
  - guides/pr-68-triage.md
decisions:
  - jido_action.spec_migration
```

## Requirements

```spec-requirements
- id: jido_action.scaffolding.install_and_generators
  statement: The repository shall ship install and generator Mix tasks that compose Igniter behavior when available and raise clear dependency guidance when Igniter is unavailable.
  priority: should
  stability: evolving

- id: jido_action.scaffolding.examples_and_support
  statement: The repository shall include a production-quality Zoi example plus maintainer-facing FAQ and PR triage guides to support adoption and ongoing maintenance.
  priority: should
  stability: evolving

- id: jido_action.scaffolding.support_guide_observability_examples
  statement: Maintainer-facing FAQ and support guides shall keep production observability examples aligned with the current execution contract, including additive action telemetry examples and sanitized success-path logging guidance.
  priority: should
  stability: evolving
```

## Verification

```spec-verification
- kind: source_file
  target: lib/mix/tasks/jido_action.install.ex
  covers:
    - jido_action.scaffolding.install_and_generators

- kind: source_file
  target: lib/mix/tasks/jido_action.gen.action.ex
  covers:
    - jido_action.scaffolding.install_and_generators

- kind: source_file
  target: lib/mix/tasks/jido_action.gen.workflow.ex
  covers:
    - jido_action.scaffolding.install_and_generators

- kind: source_file
  target: lib/examples/zoi_example.ex
  covers:
    - jido_action.scaffolding.examples_and_support

- kind: guide_file
  target: guides/faq.md
  covers:
    - jido_action.scaffolding.examples_and_support
    - jido_action.scaffolding.support_guide_observability_examples

- kind: guide_file
  target: guides/pr-68-triage.md
  covers:
    - jido_action.scaffolding.examples_and_support
```
