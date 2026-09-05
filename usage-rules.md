# Jido Action Usage Rules

## Scope

Use `jido_action` for validated work and data-first composition:

- `Jido.Action` defines one named module, one validated parameter map, one `run/2` callback, and one result.
- `Jido.Instruction` represents one requested executable call as data.
- `Jido.Flow` composes named Action calls as a validated graph.
- `Jido.Exec` runs Actions, Instructions, and Flows through one public boundary.

## Action Definitions

- Use `use Jido.Action` for public actions.
- Implement `run/2` in every Action. A missing body is a compile error.
- Provide stable `name` and useful `description` values.
- Use Zoi schemas for `schema` and `output_schema`; omit them or use `[]` only when validation is intentionally empty.
- Keep `run/2` strict: return `{:ok, result}`, `{:ok, result, extra}`,
  `{:continue, input, target}`, `{:error, reason}`, or
  `{:error, reason, extra}`.
- Return a normal map for success. Use `Jido.Action.Output` for an intentional
  raw, stream, batch, or opaque success value.
- Keep side effects explicit inside `run/2` and make them easy to test.

## Instructions

- Use `Jido.Instruction` when one requested executable call must be data before
  execution.
- Store only the executable target, params, context, and caller metadata in an
  Instruction.
- Use an Action module, Flow module, or runtime Flow value as the target.
- Pass execution options directly to `Jido.Exec`.
- Validate the executable contract explicitly when a caller needs that guarantee.

## Validation

- Validate inputs with `validate_params/1`.
- Validate outputs with `validate_output/1`.
- Use `on_before_validate_params/1` only for deterministic raw input
  preparation that must happen before Zoi validation.
- Direct object and struct schemas use open validation at the Action root:
  Jido treats Zoi `:strip` as `:preserve`, so declared keys are validated and
  unknown root keys are preserved.
- Nested and wrapped schemas use their declared Zoi `unrecognized_keys` policy.
  Jido keeps Zoi `:error` and typed preservation policies unchanged.
- Prefer precise schemas with defaults for optional action inputs.
- Use `Jido.Flow.validate/1` for canonical Flow structure and graph rules.
- Use `Jido.Flow.validate_executable/1` to also check all Flow target contracts.
- Use `Jido.Flow.Codec.encode/2` and `Jido.Flow.Codec.decode/2` with a trusted
  `Jido.Flow.Registry` for stored JSON data.
- Use `Jido.Flow.Codec.diagnose/2` when an editor needs all independent stored
  document and graph errors.

## Flow Authoring

- Use the compile-time `Jido.Flow` DSL as the primary developer authoring
  surface.
- Resolve target kinds with `Jido.Executable`. A Flow requires `flow/0` and
  validation callbacks; its generated `run/2` is a convenience function.
- Add `:jido_action` to `.formatter.exs` `import_deps` to keep DSL declarations
  without parentheses. No formatter plugin is required.
- Give every component a stable string name.
- Use `step`, `choice`, `map`, `reduce`, `iterate`, and `dispatch` for graph
  structure.
- Use `input`, `context`, and `result` references to map data. Use `Jido.Expr`
  operations for short calculations and conditions. Put application calls and
  complex work in Actions or inline bodies. See
  [Expressions](guides/flow-expressions.md) for the complete operation list.
- Treat DSL expressions as a restricted data grammar, not general Elixir. Do
  not use assignments, pattern matching, pipes, or application function calls
  in binding sources or other data expressions.
- Use `step "name", value <- input(:value) do ... end` for a small inline
  body. Use a binding list for more than two inputs, a sole map pattern for
  complete params, or `[]` for no input. Only `after:` and `meta:` are header
  options. This form requires `3.0.0-beta.5` or later.
- Write normal Elixir inside the body. The shorthand binds context with
  `ctx <- context()` as an Action parameter. Bodies retain the owner's private
  helpers and lexical scope, not runtime closure captures. Qualify helper
  calls that conflict with DSL imports, or import those helpers inside the body.
- The shipped Step shorthand has empty field schemas. The nested
  `action` form accepts `name`, `description`, `schema`, `output_schema`, and
  `context: ctx`. Schemas are static and are not inferred from bindings.
- Use nested bound `action` blocks in Step, Map, Reduce, Choice options and
  fallback, and Iterate. Dispatch uses bound `decision` and callback
  `expander` blocks. Callback input is a named variable or map pattern without
  `<-`. These forms compile to ordinary Action targets.
- `context: ctx` binds actual execution context without adding parameters or
  schema fields. Keep custom lifecycle hooks and independent public module
  APIs in named Actions. See [Portable Inline Actions](guides/inline-actions.md).
  This shared API and `Jido.Expr` require `3.0.0-beta.6` or later.
- Let result references create data dependencies. Use `after:` only for
  control order without a data dependency.
- Do not add a `parallel` block. Independent nodes run concurrently when
  `max_concurrency` is greater than `1`.
- Add one required `output` declaration to every Flow.
- The DSL, Builder, and canonical data all use the name `output`.
- Use `repeat` or a bounded `while` condition in the Spark `iterate` form. The
  lowerer converts it to canonical `completion` and `max_iterations` data.
- Keep Iterate State local to that component.
- Use at most one `dispatch`. It must be the last component and the complete
  Flow output. Run it only through a run-to-completion Exec call.

## Runtime Flow Data

- Use `Jido.Flow.Builder` only when graph structure comes from runtime data.
- Use `Jido.Flow.Codec.encode/2` for portable Map or JSON storage.
- Use `Jido.Flow.Codec.encode/1` only when a generated temporary Registry is
  sufficient. Keep its returned Registry for decoding.
- Restore stored data with `Jido.Flow.Codec.decode/2` and the same trusted
  `Jido.Flow.Registry`.
- Use `Jido.Flow.Codec.diagnose/2` when a UI or AI agent submits an invalid
  stored map. Diagnostics return ordered, path-based errors and no partial
  Flow.
- Use proper lists in runtime Flow data and non-negative integers for list path
  indexes. Invalid values return structured validation errors.
- Do not parse or evaluate stored Elixir DSL source. AI systems can produce
  stored JSON or Map data instead.
- Reuse compiled inline Actions with `FlowModule.step_action(name)` after the
  owner compiles. It returns only the target, not params, `after`, or `meta`.
  Invalid or unknown names and non-Step components raise `ArgumentError`.
- For other inline roles, use `Jido.Action.Inline.target!/2` with the exact
  owner and typed host path. It returns only the target. Supply a new source
  mapping in the receiving host; lookup does not retain old bindings.
- Register that target with a stable host-owned Action identifier for JSON.
  Register named binding keys as atoms. Do not add body, function, or MFA data
  to Builder, Registry, or Codec input.
- Deploy the owner and its generated Action BEAM files together. A body-only
  change can keep the same target and semantic graph identity. Track deployed
  code versions separately from graph identity.
- Only `Builder.step/5` and a Spark `step` can derive a Subflow from an
  executable of kind `:flow`. Choice, Map, Reduce, and Iterate target fields
  accept Actions only. Dispatch decision and expander targets also accept
  Actions only.

## Execution

- Use `Jido.Exec.run/4` for the public validation and error boundary.
- Pass `task_supervisor: reference` for a local Task.Supervisor PID, name, or
  via route. The host owns supervisor names and capacity. See
  [Runtime Configuration](guides/configuration.md#task-supervisor-references).
- All run-to-completion targets accept `max_continuations` and
  `max_concurrency`. An Action does not use the concurrency limit itself, but
  it can continue to a Flow. `max_concurrency` defaults to `8`. Use `1` for
  serial Flow execution.
- Use `run_async/4` for an asynchronous run-to-completion call. Only the owner
  process can await, handle messages for, or cancel its handle. Use
  `handle_message/2` in OTP callbacks. Await, message handling, and cancellation
  are alternative one-shot terminal consumers. An await timeout cancels that
  call.
- Use `start/4`, `ready/1`, `step/1`, `step/2`, `wave/1`, `continue/1`, and
  `result/1` for a Flow or an Instruction with a Flow target.
- Treat values from `ready/1`, `step/1`, `step/2`, and `wave/1` as small
  `Jido.Exec.Work` descriptions. Support work remains visible.
- Use `Jido.Exec.native/1` for advanced, read-only native inspection. Native
  shapes depend on the Runic version. Other Execution fields are internal.
- Select `step/2` work with a ready Work token. Refresh all tokens after each
  mutation, including tokens for work that remains ready.
- Treat each execution as caller-owned, in-memory state. `max_concurrency`
  bounds each concurrent ready wave. Always pass the latest value to the next
  step-wise call.
- Do not persist an execution as a checkpoint. Reusing a stale value can run an
  Action side effect again.
- Let the caller or Jido core select timeout and retry policy. Use `timeout:`
  with `Jido.Exec.run/4` or `run_async/4` to enforce one finite whole-call
  timeout. Exec async handles provide only owner-bound, in-memory
  cancellation. Keep retry, backoff, durable cancellation policy,
  persistence, and exactly-once behavior in the higher-level runtime.

## Package Boundary

Keep bundled domain Actions, adapter-specific conversions, and higher-level
runtime policy in separate packages.
