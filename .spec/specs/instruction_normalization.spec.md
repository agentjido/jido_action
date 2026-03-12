# Jido.Instruction

Supports package requirement `jido_action.package.instructions`.

## Intent

Define how Jido.Instruction constructs instruction structs and normalizes
shorthand inputs into executable instruction values.

```spec-meta
id: jido_action.instruction_normalization
kind: module
status: active
summary: Construction, normalization, and allowlist checks for Jido.Instruction values.
surface:
  - lib/jido_instruction.ex
  - guides/instructions-plans.md
```

## Requirements

```spec-requirements
- id: jido_action.instruction.new_contract
  statement: Jido.Instruction.new and new! shall require an atom action and apply defaults for id, params, context, and opts.
  priority: must
  stability: stable
- id: jido_action.instruction.normalize_inputs
  statement: Jido.Instruction.normalize and normalize! shall accept modules, tuples, structs, and flat lists, then merge shared context and opts into each instruction.
  priority: must
  stability: stable
- id: jido_action.instruction.allowlist_checks
  statement: Jido.Instruction.validate_allowed_actions shall reject instructions whose action is not in the allowed set.
  priority: must
  stability: stable
```

## Scenarios

```spec-scenarios
- id: jido_action.instruction.mixed_inputs_with_shared_context
  given:
    - a list mixes action modules, tuples, and instruction structs
    - a shared context is provided to normalization
  when:
    - Jido.Instruction.normalize runs
  then:
    - each item becomes a Jido.Instruction struct
    - the shared context is merged into each instruction
  covers:
    - jido_action.instruction.normalize_inputs
- id: jido_action.instruction.nested_list_rejected
  given:
    - a normalization input contains a nested list
  when:
    - Jido.Instruction.normalize runs
  then:
    - normalization returns an error instead of silently flattening input
  covers:
    - jido_action.instruction.normalize_inputs
```

## Verification

```spec-verification
- kind: command
  target: MIX_ENV=test mix test test/jido_action/instruction_test.exs
  execute: true
  covers:
    - jido_action.instruction.new_contract
    - jido_action.instruction.normalize_inputs
    - jido_action.instruction.allowlist_checks
```
