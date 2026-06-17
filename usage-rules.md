# Jido Action Usage Rules

## Scope

Use `jido_action` for leaf actions and explicit flow composition:

- `Jido.Action` defines one named module, one validated parameter map, one `run/2` callback, and one result.
- `Jido.Flow` composes actions and native Runic stateful components.
- `Jido.Exec` executes actions, instructions, and flows through Runic where composition is involved.

Keep action bodies as leaf nodes. Put composition in `Jido.Flow`, not inside `run/2`.

## Action Definitions

- Use `use Jido.Action` for public actions.
- Provide stable `name` and useful `description` values.
- Use Zoi schemas for `schema` and `output_schema`; omit them or use `[]` only when validation is intentionally empty.
- Keep `run/2` strict: return `{:ok, result}`, `{:ok, result, extra}`, `{:error, reason}`, or `{:error, reason, extra}`.
- Keep `run/2` as a leaf node. Calling `Jido.Exec.run/4` or `run_async/4` inside `run/2` emits a compile-time warning; set `@jido_allow_nested_exec true` before `run/2` only for intentional orchestrator actions.
- Keep side effects explicit inside `run/2` and make them easy to test.

## Execution

- Use `Jido.Exec.run/4` when retry, timeout, telemetry, output validation, crash normalization, or context propagation matters.
- Use `Jido.Instruction` when one requested action call needs to be represented as data before execution.
- Use `run_async/4`, `await/1`, `await/2`, and `cancel/1` for supervised async work.
- Pass request state through `context`; do not rely on hidden process state unless a context propagator is configured.
- Configure defaults with `:default_timeout`, `:default_max_retries`, and `:default_backoff`.

## Flow Composition

- Use `Jido.Flow.new/1` to create a composition value.
- Use `Jido.Flow.step/4` for leaf action steps. The `:after` option declares dependency edges.
- Use `Jido.Flow.component/4` only for native Runic components such as accumulators and state machines.
- Use `Jido.Exec.run/3` for in-process flow execution.
- Use `Jido.Exec.Runner.start_link/1` plus `Jido.Exec.start_flow/3`, `resume/3`, `results/2`, `workflow/2`, `checkpoint/2`, and `stop/2` for Runner-backed execution.
- Do not model arbitrary cyclic graph edges as the first API. Prefer repeated runtime resumes, bounded runtime cycles, and Runic stateful components.
- Set `:max_cycles` when running reactive flows that may continue producing runnable generations.

## Validation

- Validate inputs with `validate_params/1` or by running through `Jido.Exec`.
- Validate outputs with `validate_output/1` or by running through `Jido.Exec`.
- Unknown keys are preserved; only keys declared in the Zoi schema are validated.
- Prefer precise schemas with defaults for optional runtime policy values.

## Package Boundary

Keep bundled domain actions and adapter-specific conversions in separate packages. Use `Jido.Flow` and `Jido.Exec` for in-package composition and stateful execution.
