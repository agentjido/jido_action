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
- Use `MyAction.authoring_contract/0` for a JSON-safe description (stable ID, `vsn`,
  name, description, input and output JSON Schema). It is descriptive; Zoi
  validation is authoritative.
- Direct, nested, and wrapped schemas use their declared Zoi unknown-key
  policy. Add `unrecognized_keys: :preserve` to each object that must retain
  undeclared fields. Struct schemas support strip or strict behavior, and a
  parsed root struct becomes a complete plain map.

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
- Defaults: `timeout: :infinity`, `max_attempts: 1`, and `max_concurrency`
  from `config :jido_action, max_concurrency: value`. Without this
  configuration, `max_concurrency` is the smaller value of
  `System.schedulers_online()` and `10`.
- `timeout` applies to each attempt of each runnable (every Action call and
  every internal Flow node), not to the whole call. A timeout returns
  `Jido.Action.Error.TimeoutError`.
- `max_attempts` counts the first attempt. A failed runnable retries only when
  `Jido.Action.Error.retryable?/1` accepts its error. Set
  `details.retry: true` only when another attempt is safe.
- Set both `base_delay_ms` and `max_delay_ms` when you use `backoff`. Both
  default to `0`, which means no delay.
- Independent Flow components and collection items can run in parallel up to
  `max_concurrency`. An explicit `run/4` option overrides the package
  configuration. Do not add a `parallel` block; there is none.
- `Jido.Exec.run/4` runs the Action or Flow in a supervised task. It blocks
  the caller and stops work if the caller exits. The default supervisor is
  `Jido.Exec.TaskSupervisor`.
- Use `Jido.Exec.compile/2` to check targets and get the `%Runic.Workflow{}`
  without running work. Use `run/4` or `start/6` for the complete Jido
  boundary. Direct Runic integration is an advanced API; it requires the
  caller to supply root input validation, context, and process ownership.

## Managed Execution

- Use `Jido.Exec.start(runner, execution_id, target, params, context, opts)`
  for work that must be checkpointed, resumed, or observed by other processes.
  Start a `Runic.Runner` in your supervision tree first.
- Use a stable, unique `execution_id` per execution.
- `start/6` returns `{:ok, pid}` after it starts the Runner worker and requests
  dispatch. Use the `on_complete:` option or `Runic.Runner` to learn when it
  finishes.
- Use `Jido.Exec.result(runner, execution_id)` to read the managed result.
  It selects the input admitted by `start/6` and rejects active or ready work.
  After resume, it checks progress and projects the restored snapshot, which
  includes historical failures. Use `result(workflow)` for a completed
  snapshot, or `result(workflow, observation)` for a specific Runic input scope.
- Read `Runic.Runner.persistence_status/2` for Store acknowledgement. A
  computed result can still have pending or failed persistence.
- Keep managed params, context, Action outputs, and effects portable: no
  PIDs, ports, references, or functions. Managed execution rejects them.
- Managed `max_concurrency` uses the same capped package default as `run/4`.
  `task_supervisor` is not a managed option. Runic's default executor uses
  supervised tasks; custom executors define how their work runs.
- Use `Runic.Runner.checkpoint/2` and `stop/3` for lifecycle control. Resume
  with `Jido.Exec.resume/4` and the same context and options.
- For manual stepping, start with `dispatch_mode: :manual` and call
  `Jido.Exec.step(runner, execution_id)`. It returns `{:ok, workflow}`,
  `{:complete, workflow}`, or `{:error, reason}` (`:busy`,
  `:automatic_dispatch`, or `:not_found`). `{:complete, workflow}` also
  covers stopped admission; read `Jido.Exec.result(runner, execution_id)` for
  failure or uncertain work.

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
- Direct, nested, and wrapped schemas use their declared Zoi
  `unrecognized_keys` policy. Add `:preserve` to each object that must retain
  undeclared fields. Use `:error` when unknown fields must fail validation.
- Prefer precise schemas with defaults for optional Flow inputs.
- Use `Jido.Flow.validate/1` for canonical Flow structure and graph rules.
- Use `Jido.Exec.compile/2` to also check all Flow target contracts.
- Use `Jido.Authoring.encode/2` and `Jido.Authoring.decode/2` with a trusted
  `Jido.Authoring.Registry` for stored JSON data.
- Use the ordered issues from `Jido.Authoring.decode/2` when an editor needs
  stored document and graph errors.

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
- Use at most one `dispatch`. It must be the sole graph terminal, and `output`
  must be its complete result. Source order does not determine the terminal.
- Every execution host must handle the standard terminal Dispatch result
  `{:handoff, %Jido.Instruction{}, effects}` as predecessor completion
  and atomic successor acceptance. See `guides/dynamic-flows.md` for host rules.
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
- `and` and `or` require a Boolean left operand and return the evaluated right
  value unchanged. `not` requires a Boolean. Flow condition slots require a
  Boolean final value. There is no implicit type conversion.

## Flows As Data

- Use `Jido.Flow.new/1` with a map of `name`, `components` (a list of tagged
  maps with `kind:`), and `output` to build a Flow at runtime.
- Use `Jido.Flow.Ref` constructors (`input/1`, `result/2`, `item/1`, ...) and
  `Jido.Expr.new/2` for references and operations in data definitions.
- Use `kind: :step` with `action:` and `params:` for an Action, and
  `kind: :subflow` with `flow:` and `params:` for a child Flow.
- Dispatch uses modules in `decision:` and `expander:`, with `params:` for
  the decision.
- Data definitions use only these authoring fields. `Jido.Flow.new/1` rejects
  internal call records.
- Store all current features with document `vsn` 1. Other `vsn` values are
  rejected. Data and JSON use the same validation error order.
- Use `Jido.Authoring.encode/2` and `decode/2` with an application-owned
  `Jido.Authoring.Registry` for stored or transported Flows. Keep Registry
  IDs and `vsn` values stable.
- Use the ordered issues from `Jido.Authoring.decode/2` when an editor or AI
  needs errors with document paths.
- Never evaluate stored or generated Elixir source to build a Flow.

## Runtime JSON Authoring

- Give stored Action and Flow references an explicit stable `id:`. Use
  `vsn:` when the authored module contract is not version 1.
- Configure `Jido.Discovery` under `:jido_action`. Use an application allowlist
  for editor or network input.
- The startup scan includes Action and Flow manifests from `:jido_action` and
  keeps them as separate Registry kinds. Include each provider application in
  configuration or refresh Discovery after that application starts.
- Use `Jido.Discovery.list/0`, `list/1`, `get/2`, and `get_by_target/2` for
  Action, Flow, schema, and atom entries.
- Use `Jido.Authoring.encode/2` or `encode_json/2` to encode a canonical value
  through its discovered codec.
- Use `Jido.Authoring.decode_json/2` for JSON text and
  `Jido.Authoring.decode/2` for decoded JSON data.
- JSON documents default to 8 MiB. Configure `Jido.Authoring` under
  `:jido_action` or pass `maximum_json_bytes:` to `encode/2`, `encode_json/2`,
  `decode/2`, or `decode_json/2` for one call.
- Handle invalid input as an ordered list of `%Jido.Authoring.Issue{}` values.
  Use stable issue codes and source JSON paths in an editor.
- Publish schema and atom entries from a static
  `__jido_authoring__/0` function when Action and Flow module entries are not
  sufficient.
- Treat Discovery as an inventory. Apply application authorization before you
  run a decoded Flow.

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

## Flow Waits

- Use `timer`, `await`, or `selection` to define named waits.
  Keep explicit dependencies and output. A Selection contains timers and events only.
- Use `Jido.Flow.validate/1` and `Jido.Exec.compile/2` to check wait definitions
  without executing them. Normal Exec rejects waits. Use a durable host with
  `Jido.Exec.Waits` operations and native Runic execution instead.
  A Dispatch-selected waiting Flow is rejected before child Action work.
- Use the driver and ETS Store in `test/support` only for package tests.
  They are not shipped APIs. `Jido.Exec.Waits` supplies request inspection,
  matching, and resolution without Action or hook execution. The host owns
  input receipts, clock policy, limits, and storage. Save accepted input before
  acknowledgement and resolution before resuming Runic.
  Read `guides/flow-waits.md` for the host contract.
