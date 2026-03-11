# Jido.Exec Chains

Supports package requirement `jido_action.package.execution_chains`.

## Intent

Define how Jido.Exec.Chain composes action pipelines, handles interruption, and
isolates async chain supervision from the caller.

```spec-meta
id: jido_action.exec.chains
kind: workflow
status: active
summary: Chain composition, interruption, and async supervision for Jido.Exec.Chain.
surface:
  - lib/jido_action/exec/chain.ex
  - guides/execution-engine.md
```

## Requirements

```spec-requirements
- id: jido_action.exec.chain_composition
  statement: Jido.Exec.Chain shall compose actions from modules, tuples, and action-option pairs while passing intermediate params through the chain.
  priority: must
  stability: stable
- id: jido_action.exec.chain_interrupts
  statement: Jido.Exec.Chain shall stop cleanly when an interrupt check requests early exit and return the partial result accumulated so far.
  priority: must
  stability: stable
- id: jido_action.exec.chain_supervision
  statement: Async chain execution shall run in an unlinked task and optionally route through an instance-specific task supervisor.
  priority: must
  stability: stable
```

## Verification

```spec-verification
- kind: command
  target: MIX_ENV=test mix test test/jido_action/exec/chain_test.exs test/jido_action/exec/chain_interrupt_test.exs test/jido_action/exec/chain_supervision_test.exs
  execute: true
  covers:
    - jido_action.exec.chain_composition
    - jido_action.exec.chain_interrupts
    - jido_action.exec.chain_supervision
```
