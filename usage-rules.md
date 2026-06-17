# Jido Action Usage Rules

## Scope

Use `jido_action` for leaf actions: one named module, one validated parameter map, one `run/2` callback, and one result.

Keep higher-level orchestration outside this package.

## Action Definitions

- Use `use Jido.Action` for public actions.
- Provide stable `name` and useful `description` values.
- Use Zoi schemas for `schema` and `output_schema`; omit them or use `[]` only when validation is intentionally empty.
- Keep `run/2` strict: return `{:ok, result}`, `{:ok, result, extra}`, `{:error, reason}`, or `{:error, reason, extra}`.
- Keep side effects explicit inside `run/2` and make them easy to test.

## Execution

- Use `Jido.Exec.run/4` when retry, timeout, telemetry, output validation, crash normalization, or context propagation matters.
- Use `run_async/4`, `await/1`, `await/2`, and `cancel/1` for supervised async work.
- Pass request state through `context`; do not rely on hidden process state unless a context propagator is configured.
- Configure defaults with `:default_timeout`, `:default_max_retries`, and `:default_backoff`.

## Validation

- Validate inputs with `validate_params/1` or by running through `Jido.Exec`.
- Validate outputs with `validate_output/1` or by running through `Jido.Exec`.
- Unknown keys are preserved; only keys declared in the Zoi schema are validated.
- Prefer precise schemas with defaults for optional runtime policy values.

## Package Boundary

Keep this package focused on defining, validating, and executing one action at a time. Put higher-level orchestration, adapter-specific conversion, and bundled domain actions in separate packages.
