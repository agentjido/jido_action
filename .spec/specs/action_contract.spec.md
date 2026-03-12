# Jido.Action

Supports package requirement `jido_action.package.actions`.

## Intent

Define how Jido.Action turns modules into validated, composable actions
with compile-time metadata, schema-aware validation, and overridable hooks.

```spec-meta
id: jido_action.action_contract
kind: module
status: active
summary: Core action behavior and lifecycle contract for Jido.Action modules.
surface:
  - lib/jido_action.ex
  - lib/jido_action/runtime.ex
  - guides/actions-guide.md
  - guides/schemas-validation.md
```

## Requirements

```spec-requirements
- id: jido_action.action.metadata_exports
  statement: use Jido.Action shall generate metadata accessors plus JSON-serializable action metadata from compile-time configuration.
  priority: must
  stability: stable
- id: jido_action.action.validation_contract
  statement: The action contract shall validate declared input and output fields while preserving unspecified fields for composition.
  priority: must
  stability: stable
- id: jido_action.action.lifecycle_hooks
  statement: The action contract shall expose overridable hooks before and after validation and after run.
  priority: must
  stability: stable
```

## Scenarios

```spec-scenarios
- id: jido_action.action.output_validation_preserves_extra_fields
  given:
    - an action declares an output schema with required fields
    - the action returns those required fields plus extra data
  when:
    - the action runs through Jido.Exec
  then:
    - the declared output fields validate
    - the extra data is preserved in the result
  covers:
    - jido_action.action.validation_contract
- id: jido_action.action.after_run_can_transform_result
  given:
    - an action overrides on_after_run/1
  when:
    - the hook receives a successful action result
  then:
    - the hook can transform the result
    - the result stays a single {:ok, map()} tuple
  covers:
    - jido_action.action.lifecycle_hooks
```

## Verification

```spec-verification
- kind: command
  target: MIX_ENV=test mix test test/jido_action/action_test.exs test/jido_action/on_after_run_test.exs test/jido_action/zoi_schema_test.exs
  execute: true
  covers:
    - jido_action.action.metadata_exports
    - jido_action.action.validation_contract
    - jido_action.action.lifecycle_hooks
```
