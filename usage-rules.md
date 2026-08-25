# Jido Action Usage Rules

## Scope

Use `jido_action` for validated work and data-first composition:

- `Jido.Action` defines one named module, one validated parameter map, one `run/2` callback, and one result.
- `Jido.Instruction` represents one requested executable call as data.
- `Jido.Flow` composes named Action calls as a validated graph.
- `Jido.Exec` runs Actions, Instructions, and Flows through one public boundary.

## Action Definitions

- Use `use Jido.Action` for public actions.
- Provide stable `name` and useful `description` values.
- Use Zoi schemas for `schema` and `output_schema`; omit them or use `[]` only when validation is intentionally empty.
- Keep `run/2` strict: return `{:ok, result}`, `{:ok, result, extra}`, `{:error, reason}`, or `{:error, reason, extra}`.
- Return a normal map for success. Use `Jido.Action.Output` for an intentional
  raw, stream, batch, or opaque success value.
- Keep side effects explicit inside `run/2` and make them easy to test.

## Instructions

- Use `Jido.Instruction` when one requested executable call must be data before
  execution.
- Store only the executable target, params, context, and caller metadata in an
  Instruction.
- Use an Action module, Flow module, or runtime Flow value as the target.
- Validate the executable contract explicitly when a caller needs that guarantee.

## Validation

- Validate inputs with `validate_params/1`.
- Validate outputs with `validate_output/1`.
- Unknown keys are preserved; only keys declared in the Zoi schema are validated.
- Prefer precise schemas with defaults for optional action inputs.
- Use `Jido.Flow.validate/1` for canonical Flow structure and graph rules.
- Use `Jido.Flow.validate_executable/1` to also check all Flow target contracts.
- Use `Jido.Flow.Codec.encode/2` and `Jido.Flow.Codec.decode/2` with a trusted
  `Jido.Flow.Registry` for stored JSON data.

## Flow Authoring

- Use the compile-time `Jido.Flow` DSL as the primary developer authoring
  surface.
- Give every component a stable string name.
- Use `step`, `choice`, `map`, `reduce`, and `iterate` for graph structure.
- Use `input`, `context`, and `result` references to map data. Put computation
  in Actions.
- Treat DSL expressions as a restricted data grammar, not general Elixir. Do
  not use assignments, pattern matching, pipes, or application function calls.
- Let result references create data dependencies. Use `after:` only for
  control order without a data dependency.
- Do not add a `parallel` block. Independent nodes are already parallel when
  Flow execution uses `async: true`.
- Add one required `output` declaration to every Flow.
- The DSL, Builder, and canonical data all use the name `output`.
- Use `repeat` or a bounded `while` condition in the Spark `iterate` form. The
  lowerer converts it to canonical `completion` and `max_iterations` data.
- Keep Iterate State local to that component.

## Runtime Flow Data

- Use `Jido.Flow.Builder` only when graph structure comes from runtime data.
- Use `Jido.Flow.Codec.encode/2` for portable Map or JSON storage.
- Restore stored data with `Jido.Flow.Codec.decode/2` and the same trusted
  `Jido.Flow.Registry`.
- Use the returned structured error as feedback when a UI or AI agent submits
  an invalid stored map. The reader does not raise for validation failures.
- Use proper lists in runtime Flow data and non-negative integers for list path
  indexes. Invalid values return structured validation errors.
- Do not parse or evaluate stored Elixir DSL source. AI systems can produce
  stored JSON or Map data instead.
- Only `Builder.step/5` and a Spark `step` can derive a Subflow from an
  executable of kind `:flow`. Choice, Map, Reduce, and Iterate target fields
  accept Actions only.

## Execution

- Use `Jido.Exec.run/4` for the public validation and error boundary.
- Use `jido: MyApp.Jido` with an Action, Instruction, or Flow when work must run
  under the Task Supervisor for that running Jido core instance.
- A Flow or an Instruction with a Flow target also accepts `async` and
  `max_concurrency` policy options.
- Use `start/4`, `ready/1`, `step/1`, `step/2`, `wave/1`, `continue/1`, and
  `result/1` for a Flow or an Instruction with a Flow target.
- Treat values from `ready/1`, `step/1`, `step/2`, and `wave/1` as native
  `Runic.Workflow.Runnable` values. Runic support work is visible.
- Select `step/2` work with a ready Runnable or its integer ID.
- Treat each execution as caller-owned, in-memory state with its own
  concurrency limit. Always pass the latest value to the next step-wise call.
- Do not persist an execution as a checkpoint. Reusing a stale value can run an
  Action side effect again.
- Keep retry, timeout, cancellation, persistence, and exactly-once policy in
  the caller or a higher-level runtime.

## Package Boundary

Keep bundled domain Actions, adapter-specific conversions, and higher-level
runtime policy in separate packages.
