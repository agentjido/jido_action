# Jido Action Usage Rules

Rules for code that uses `jido_action` version 3. Each rule names the public
API to use. See the guides on HexDocs for explanations and examples.

## Mental Model

- `Jido.Action` defines one validated unit of work: input schema, `run/2`,
  output schema.
- `Jido.Instruction` holds one call as data: target, params, context, metadata.
- `Jido.Flow` composes Action calls as a validated graph with one explicit
  `output`.
- `Jido.Exec` is the only execution boundary. It compiles every target to a
  `Runic.Workflow` and runs it.
- Runic owns scheduling, retries, timeouts, checkpoints, and resume. Your
  application owns effects, authorization, and secrets.

## Actions

- Define Actions with `use Jido.Action, name: ..., schema: ..., output_schema: ...`.
  `name` is required. Implement `run/2`; a missing `run/2` is a compile error.
- Use Zoi schemas. Omit a schema (or use `[]`) only when validation is
  intentionally empty. Schemas must accept maps.
- Keep schemas static. Do not use anonymous functions or `Zoi.lazy` in
  schemas. Use MFA tuples for refinements and transforms:
  `Zoi.refine({__MODULE__, :check, []})`.
- Return a map on success: `{:ok, %{...}}`. Use `Jido.Action.Output.raw/2`,
  `stream/2`, `batch/2`, or `opaque/2` only for intentional non-map values.
- Return `{:error, reason}` on failure. Prefer a `Jido.Action.Error` struct,
  such as `Jido.Action.Error.validation_error/2`, when callers can act on it.
- Return deferred effects as a proper list in a third element:
  `{:ok, result, [request, ...]}`. Exec returns them and never performs them.
  The effects of `{:error, reason, effects}` are discarded.
- Put request IDs, tenants, and other caller data in context, not params.
- Implement `on_before_validate_params/1` only for raw input preparation that
  Zoi coercion and defaults cannot express.
- Use `MyAction.to_json/0` for a JSON-safe description (name, description,
  input and output JSON Schema). It is descriptive; Zoi validation is
  authoritative.
- Object schemas are open at the root: undeclared keys pass through. Set
  `unrecognized_keys:` on nested objects that must reject or preserve keys.

## Running Work

- Use `Jido.Exec.run(target, params, context, opts)`. The target can be an
  Action module, Flow module, `%Jido.Flow{}`, or `%Jido.Instruction{}`.
- Match all three result shapes: `{:ok, value}`, `{:ok, value, effects}`, and
  `{:error, exception}`.
- Do not call `MyAction.run/2` directly in application code. It skips
  validation and error normalization. Direct calls are fine in unit tests.
- Pass only these `run/4` options: `timeout`, `max_attempts`, `backoff`,
  `base_delay_ms`, `max_delay_ms`, `max_concurrency`, and `task_supervisor`.
  Unknown options return a configuration error.
- Defaults: `timeout: :infinity`, `max_attempts: 1`, `max_concurrency: 1`
  (serial).
- `timeout` applies to each attempt of each runnable (every Action call and
  every internal Flow node), not to the whole call. A timeout returns
  `Jido.Action.Error.TimeoutError`.
- `max_attempts` counts the first attempt. A failed runnable retries only when
  `Jido.Action.Error.retryable?/1` accepts its error. Set
  `details.retry: true` only when another attempt is safe.
- Set both `base_delay_ms` and `max_delay_ms` when you use `backoff`. Both
  default to `0`, which means no delay.
- Set `max_concurrency` above `1` to run independent Flow components and
  collection items in parallel. Do not add a `parallel` block; there is none.
- `run/4` blocks the caller. The work runs in a task under
  `Jido.Exec.TaskSupervisor` and stops if the caller exits.
- Use `Jido.Exec.compile/2` to check targets and get the `%Runic.Workflow{}`
  without running work. Do not feed that workflow to Runic yourself; use
  `run/4` or `start/6`.

## Managed Execution

- Use `Jido.Exec.start(runner, execution_id, target, params, context, opts)`
  for work that must be checkpointed, resumed, or observed by other processes.
  Start a `Runic.Runner` in your supervision tree first.
- Use a stable, unique `execution_id` per execution.
- `start/6` returns `{:ok, pid}` after it starts the Runner worker and requests
  dispatch. Use the `on_complete:` option or `Runic.Runner` to learn when it
  finishes.
- Read the final workflow with `Runic.Runner.get_workflow/2`, then use
  `Jido.Exec.result/1` to get the same result contract as `run/4`.
- Keep managed params, context, Action outputs, and effects portable: no
  PIDs, ports, references, or functions. Managed execution rejects them.
- Managed `max_concurrency` defaults to `System.schedulers_online()`, not `1`.
  `task_supervisor` is not a managed option.
- Use `Runic.Runner.checkpoint/2` and `stop/3` for lifecycle control. Resume
  with `Jido.Exec.resume/4` and the same context and options.
- For manual stepping, start with `dispatch_mode: :manual` and call
  `Jido.Exec.step(runner, execution_id)`. It returns `{:ok, workflow}`,
  `{:complete, workflow}`, or `{:error, reason}` (`:busy`,
  `:automatic_dispatch`, or `:not_found`). `{:complete, workflow}` also
  covers terminal failure and drained uncertain work; call `Jido.Exec.result/1`.
  Use `Runic.Runner.admission_status/2` to inspect stopped admission and active work.

## Instructions

- Build Instructions with `Jido.Instruction.new/1` or `new!/1` and the
  `:target` key. `:action`, `:flow`, `:id`, and `:opts` are rejected.
- Pass execution options to `Jido.Exec`, not to the Instruction.
- Call-site params and context passed to `Jido.Exec.run/4` shallow-merge over
  the Instruction's values.
- Do not store Instructions as JSON. Store Flows with `Jido.Flow.Codec`.

## Flow Modules

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

- Use `use Jido.Flow, name: ...` and a `flow do ... end` block as the normal
  way to write a Flow. Add `schema:` and `output_schema:` for Flow input and
  output.
- Add `:jido_action` to `import_deps` in `.formatter.exs`.
- Give every component a unique string name.
- End every Flow with `output <expression>`. It is required and must be the
  last declaration. There is no `return` alias and no inferred output.
- Read data with `input(:key)`, `context(:key)`, and `result("name", path)`.
  A `result/2` reference creates a dependency. Source order does not.
- Use `needs: ["name"]` only for ordering without a data dependency.
- Use `step` for one Action or child Flow, `choice` for ordered conditions
  with a required fallback, `map` for per-item work, `reduce` for an ordered
  fold, `iterate` for a bounded loop with state, and `dispatch` for runtime
  target selection.
- Use Action modules for `map`, `reduce`, `choice`, `iterate`, and `dispatch`
  targets. Inline bodies are supported only in `step`.
- Use at most one `dispatch`. It must be the last component, and `output` must
  be its complete result.
- Return `{:continue, input, target}` only from a Dispatch expander. Every
  other Action, including a root Action, fails with
  `reason: :unsupported_continuation`.
- Bound `iterate` with `repeat` or `while` plus `max_iterations`.
- Use `Jido.Flow.Extension` for shared authoring macros that expand to normal
  declarations. Do not use extensions to add component types or runtime
  behavior.
- A Flow module generates `flow/0` (the `%Jido.Flow{}` value), `run/2`,
  `compiled/0`, `step_action/1`, `validate_params/1`, `validate_output/1`,
  `name/0`, `description/0`, `schema/0`, and `output_schema/0`.
- Make the Flow `output` a map. Return `Jido.Action.Output` from an Action for
  intentional non-map values.

## Inline Steps

- Write `step "name", var <- input(:key) do ... end` for small local work. The
  body is normal Elixir and must return an Action result.
- Use a list for several bindings: `[a <- input(:a), b <- result("x", :b)]`.
  Use a sole map pattern for the complete source, and `[]` for no input.
- Binding sources accept references and literal data only. Put calculations
  in the body.
- Put Action settings in `inline: [name:, description:, schema:,
  output_schema:, context: ctx]`. Keep `needs:` and `meta:` on the step.
- Use `case` inside the body for pattern selection. Top-level clause bodies
  are not supported in Flow steps.
- Use `FlowModule.step_action("name")` to reuse a compiled step's Action in
  data definitions or a Registry. Do not store generated module names.
- Use a named Action module when the work needs reuse, hooks, or its own
  public API.

## Expressions

- Use `Jido.Expr` operations in Flow fields and conditions: `==`, `!=`, `<`,
  `<=`, `>`, `>=`, `in`, `and`, `or`, `not`, `+`, `-`, `*`, `/`, `div`, `rem`,
  `min`, `max`, `abs`, and `<>`.
- Do not use pipes, function calls, `&&`, `||`, `===`, tuples, or ranges in
  Flow expressions. Put that logic in an Action.
- `and`, `or`, and `not` require Boolean operands. There is no implicit type
  conversion.

## Flows As Data

- Use `Jido.Flow.new/1` with a map of `name`, `components` (a list of tagged
  maps with `kind:`), and `output` to build a Flow at runtime.
- Use `Jido.Flow.Ref` constructors (`input/1`, `result/2`, `item/1`, ...) and
  `Jido.Expr.new/2` for references and operations in data definitions.
- Use `kind: :subflow` with `flow:` for a child Flow in data definitions.
- Use `Jido.Flow.Codec.encode/2` and `decode/2` with an application-owned
  `Jido.Flow.Registry` for stored or transported Flows. Keep Registry
  identifiers stable.
- Use `Jido.Flow.Codec.encode/1` only for temporary storage within one
  application version. Keep the Registry it returns.
- Use `Jido.Flow.Codec.diagnose/2` when an editor or AI needs every error with
  its document path.
- Never evaluate stored or generated Elixir source to build a Flow.

## Validation And Inspection

- Use `Jido.Flow.validate/1` for inert structural checks. It does not load
  target modules.
- Use `Jido.Exec.compile/2` to also check Action and child Flow contracts.
- Use `Jido.Flow.dependencies/1`, `explain/1`, and `semantic_identity/1` for
  inspection. None of them runs Action work.

## Errors

- Expect `Jido.Action.Error.*` structs for Action failures and
  `Jido.Flow.Error.*` structs for Flow definition and coordination failures.
- Use `Exception.message/1` for people and `Jido.Flow.Error.to_map/1` for logs
  and APIs. It handles both error families; `Jido.Action.Error.to_map/1`
  handles only Action errors.
- An Action that fails inside a Flow keeps its `Jido.Action.Error` type and
  adds `details.node` and `details.node_path`.
- `retryable?/1` reads `details.retry`. Exec uses it to decide whether
  `max_attempts` can schedule another attempt.
- Match on the struct module and `details`, not on message text.

## Testing

- Unit test an Action with `validate_params/1`, `run/2`, and
  `validate_output/1`. Test the boundary with `Jido.Exec.run/4`.
- Test Flow definitions with `Jido.Flow.new/1` and `validate/1` before
  running them.
- Synchronize concurrent tests with messages, not `Process.sleep/1`.
- Use unique Runner names and execution IDs in managed execution tests.

## Package Boundary

- Keep domain Actions, adapters, and higher-level runtime policy (durable
  queues, distributed coordination, effect delivery) in other packages.
