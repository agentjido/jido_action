# Jido Action Usage Rules

## Scope

Use `jido_action` for leaf actions and explicit action call frames:

- `Jido.Action` defines one named module, one validated parameter map, one `run/2` callback, and one result.
- `Jido.Instruction` represents one requested action call as data.

## Action Definitions

- Use `use Jido.Action` for public actions.
- Provide stable `name` and useful `description` values.
- Use Zoi schemas for `schema` and `output_schema`; omit them or use `[]` only when validation is intentionally empty.
- Keep `run/2` strict: return `{:ok, result}`, `{:ok, result, extra}`, `{:error, reason}`, or `{:error, reason, extra}`.
- Keep side effects explicit inside `run/2` and make them easy to test.

## Instructions

- Use `Jido.Instruction` when one requested action call needs to be represented as data before execution.
- Store only the action module, params, and context in an instruction.
- Validate the action callback contract explicitly when a caller needs that guarantee.

## Validation

- Validate inputs with `validate_params/1`.
- Validate outputs with `validate_output/1`.
- Unknown keys are preserved; only keys declared in the Zoi schema are validated.
- Prefer precise schemas with defaults for optional action inputs.

## Package Boundary

Keep bundled domain actions, adapter-specific conversions, and higher-level orchestration in separate packages.
