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
- Use `to_json/0` when a host needs provider-neutral Action metadata and JSON
  Schema descriptions. Treat the result as descriptive data. Runtime Zoi
  validation remains authoritative.
- Keep `run/2` strict: return `{:ok, result}`, `{:ok, result, effects}`,
  `{:error, reason}`, or `{:error, reason, effects}`. Only a Dispatch expander
  can return `{:continue, input, target}`.
- Return a normal map for success. Use `Jido.Action.Output` for an intentional
  raw, stream, batch, or opaque success value.
- Keep side effects explicit inside `run/2` and make them easy to test.

## Instructions

- Use `Jido.Instruction` when one requested executable call must be data before
  execution.
- Store only the resolved kind, target, params, context, and caller metadata in
  an Instruction.
- Use an Action module, Flow module, or runtime Flow value as the target.
- Pass execution options directly to `Jido.Exec`.
- Use `Jido.Instruction.validate/1` when a caller needs an explicit target
  contract check.

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
- Use `Jido.Exec.compile/2` to also check all Flow target contracts.
- Use `Jido.Flow.Codec.encode/2` and `Jido.Flow.Codec.decode/2` with a trusted
  `Jido.Flow.Registry` for stored JSON data.
- Use `Jido.Flow.Codec.diagnose/2` when an editor needs all independent stored
  document and graph errors.

## Flow Authoring

- Use the compile-time `Jido.Flow` DSL as the primary developer authoring
  surface.
- Use `Jido.Flow.Extension` for shared authoring macros that expand to normal
  Flow declarations. Configure extensions with the static `extensions:` list.
  Do not add component types or runtime behavior through an extension.
- Resolve target kinds with `Jido.Instruction`. An Action module implements
  `Jido.Action`. A Flow module implements `Jido.Flow` and provides `flow/0`.
- Add `:jido_action` to `.formatter.exs` `import_deps` to keep DSL declarations
  without parentheses. No formatter plugin is required.
- Give every component a stable string name.
- Use `step`, `choice`, `map`, `reduce`, `iterate`, and `dispatch` for graph
  structure.
- Use `input`, `context`, and `result` references to map data. Use `Jido.Expr`
  operations for short calculations in explicit Flow fields and for conditions.
  Do not use operations in inline binding sources. Put those calculations,
  application calls, and complex work in Actions or inline bodies. See
  [Expressions](guides/flow-expressions.md) for the complete operation list.
- Treat DSL expressions as a restricted data grammar, not general Elixir. Do
  not use assignments, pattern matching, pipes, or application function calls
  in data expressions.
- Use `step "name", value <- input(:value) do ... end` for a small inline
  body. Use a binding list for two or more inputs, a sole map pattern for
  complete params, or `[]` for no input. Header options are `needs:`, `meta:`, and `inline:`. This form requires `3.0.0-beta.5` or later.
- Write normal Elixir inside the body. The shorthand binds context with
  `ctx <- context()` as an Action parameter. Bodies retain the owner's private
  helpers and lexical scope, not runtime closure captures. Qualify helper
  calls that conflict with DSL imports, or import those helpers inside the body.
- Use one binding argument and an ordinary Elixir expression body per inline
  Step. Use `case` inside the body for pattern selection. Flow rejects separate
  binding arguments and top-level clause bodies. Downstream hosts can still
  use clause bodies through `Jido.Action.Inline`.
- Use the direct Step body for a Flow inline Action. Its optional `inline:`
  settings are `name`, `description`, `schema`, `output_schema`, and
  `context`. Schemas are static and are not inferred from bindings.
- Use Action modules for Map, Reduce, Choice targets, Iterate, and
  Dispatch. Flow does not support inline bodies in these advanced components.
  Targets can be handwritten or generated by a downstream compile-time DSL.
- `context: ctx` binds actual execution context without adding parameters or
  schema fields. Keep custom lifecycle hooks and independent public module
  APIs in named Actions. See [Inline Actions](guides/inline-actions.md).
  This shared API and `Jido.Expr` require `3.0.0-beta.6` or later.
- Let result references create data dependencies. Use `needs:` only for
  control order without a data dependency.
- Do not add a `parallel` block. Independent nodes run concurrently when
  `max_concurrency` is greater than `1`.
- Canonical Flow data, the module DSL, data definitions, and Codec require an explicit
  `output`. In the module DSL, `output` must be the final declaration.
- The DSL, data definitions, and canonical data all use the name `output`.
- Use `repeat` or a bounded `while` condition in the Spark `iterate` form. The
  lowerer converts it to canonical `completion` and `max_iterations` data.
- Keep Iterate State local to that component.
- Use at most one `dispatch`. It must be the last component and the complete
  Flow output. Run it only through a run-to-completion Exec call.

## Runtime Flow Data

- Use `Jido.Flow.new/1` for map-based definitions, including runtime graphs.
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
  owner compiles. It returns only the target, not params, `needs`, or `meta`.
  Invalid or unknown names and non-Step components raise `ArgumentError`.
- Register that target with a stable host-owned Action identifier for JSON.
  Register named binding keys as atoms. Do not add body, function, or MFA data
  to data definitions, Registry, or Codec input.
- Deploy the owner and its generated Action BEAM files together. A body-only
  change can keep the same target and semantic graph identity. Track deployed
  code versions separately from graph identity.
- Data definitions use `kind: :subflow` and a `flow` target for child Flows.
  A Spark `step` can derive a Subflow from an executable of kind `:flow`.
  Choice, Map, Reduce, and Iterate target fields
  accept Actions only. Dispatch decision and expander targets also accept
  Actions only.

## Execution

- Use `Jido.Exec.run/4` for the public validation and error boundary. Exec
  compiles the target to a Runic workflow and runs it in an unlinked task under
  `Jido.Exec.TaskSupervisor`. Caller exit stops that task. An Action crash or
  kill returns a structured error and does not exit the caller.
- Pass `task_supervisor: reference` for a local Task Supervisor PID, name, or
  via reference. The host owns supervisor names and capacity. See
  [Runtime Configuration](guides/configuration.md).
- `timeout:` is a per-attempt Runic timeout in milliseconds. It defaults to
  `:infinity`.
- `max_attempts:` counts the first attempt. Exec retries a failed attempt only
  when its error is retryable. Set `details.retry: true` on an error only when
  another attempt is safe. Timeouts and process exits are not retried. Use
  `backoff`, `base_delay_ms`, and `max_delay_ms` for retry delay.
- `max_concurrency:` must be a positive integer. It defaults to `1`, which runs
  Flow work serially. A halting failure stops new dispatch. Work that already
  started can finish.
- Use `Jido.Exec.compile/2` when you need the native `Runic.Workflow`.
- Use `Jido.Exec.start/6` with a supervised `Runic.Runner` for managed or
  durable execution. Parameters, context, and Instruction metadata must hold
  portable values. Use `dispatch_mode: :manual` with `Jido.Exec.step/2` for
  stepwise dispatch.
- Runic does not persist runtime context or runtime policy. Resume with
  `Jido.Exec.resume/4` and the same context and options. Use
  `Jido.Exec.result/1` to project a managed workflow to the `run/4` result.
  Use `Runic.Runner` for checkpoint, stop, and inspection.
- Exec does not dispatch effects or follow Action continuations other than a
  Dispatch expander continuation. It provides no exactly-once guarantee. Keep
  durable intent, effect delivery, and deduplication in the host. Use
  `Jido.Exec.effect_id/4` for a stable effect identity.
- Telemetry handlers run synchronously. Keep them short.

## Package Boundary

Keep bundled domain Actions, adapter-specific conversions, and higher-level
runtime policy in separate packages.

## Deferred Effect Requests

Return `{:ok, output, requests}` from an Action to
request effects after success. Flow collects these opaque requests in canonical
dependency order and returns the complete batch with its final output. Exec
does not execute effects. Failed execution returns no executable batch.
The optional third success element must be a proper list of effect requests.
See [Execution](guides/execution.md#results-and-errors) for ordering, collections, and errors.
