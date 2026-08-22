# Jido Action Usage Rules

## Scope

Use `jido_action` for validated work and data-first composition:

- `Jido.Action` defines one named module, one validated parameter map, one `run/2` callback, and one result.
- `Jido.Instruction` represents one requested action call as data.
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

- Use `Jido.Instruction` when one requested action call needs to be represented as data before execution.
- Store only the action module, params, and context in an instruction.
- Validate the action callback contract explicitly when a caller needs that guarantee.

## Validation

- Validate inputs with `validate_params/1`.
- Validate outputs with `validate_output/1`.
- Unknown keys are preserved; only keys declared in the Zoi schema are validated.
- Prefer precise schemas with defaults for optional action inputs.
- Use `Jido.Flow.validate/1` for canonical Flow structure and graph rules.
- Use `Jido.Flow.validate_executable/1` to also check all Flow target contracts.
- Use `Jido.Flow.to_stored_map/3` with a trusted `Jido.Flow.Registry` to
  validate and produce stored JSON data without raising.

## Flow Authoring

- Use the compile-time `Jido.Flow` DSL as the primary developer authoring
  surface.
- Give every node a stable string name.
- Use `step`, `choice`, `map`, `reduce`, and `iterate` for graph structure.
- Use `input`, `context`, and `result` references to map data. Put computation
  in Actions.
- Let result references create data dependencies. Use `after:` only for
  control order without a data dependency.
- Do not add a `parallel` block. Independent nodes are already parallel when
  Flow execution uses `async: true`.
- Omit `output` when the complete result of the final node is correct. Use one
  final `output` declaration to shape a result from one or more nodes.
- Use `repeat` or a bounded `while` condition for `iterate`. Keep Iterator
  State local to that node.

## Runtime Flow Data

- Use `Jido.Flow.Builder` only when graph structure comes from runtime data.
- Use `Jido.Flow.to_stored_map/3` for portable Map or JSON storage.
- Restore stored data with `Jido.Flow.from_stored_map/2` and the same trusted
  `Jido.Flow.Registry`.
- Use the returned structured error as feedback when a UI or AI agent submits
  an invalid stored map. The reader does not raise for validation failures.
- Do not parse or evaluate stored Elixir DSL source. AI systems can produce
  stored JSON or Map data instead.

## Execution

- Use `Jido.Exec.run/4` for the public validation and error boundary.
- Only Flow execution accepts `async` and `max_concurrency` options.
- Use `start/4`, `ready/1`, `step/1`, `step/2`, `wave/1`, `continue/1`, and
  `result/1` for step-wise Flow execution.
- Always pass the latest execution value to the next step-wise call.
- Keep retry, timeout, cancellation, persistence, and exactly-once policy in
  the caller or a higher-level runtime.

## Package Boundary

Keep bundled domain Actions, adapter-specific conversions, and higher-level
runtime policy in separate packages.
