# AGENTS.md

## Scope

These instructions apply to the `jido_action` package on the v3 beta line.
Treat this package as foundational code for the Jido ecosystem. Correct
behavior, deterministic results, process cleanup, clear errors, and a stable
public API have priority over fast changes.

Do not treat this code as a disposable spike. Do not restore v2 behavior or
add a compatibility layer unless the user asks for it.

## Package Boundary

The package has four public parts:

- `Jido.Action` defines one named and validated unit of work.
- `Jido.Instruction` is data for one Action or Flow call.
- `Jido.Flow` defines a validated, declarative graph of Action calls.
- `Jido.Exec` is the execution and error boundary. It compiles every target
  to a `Runic.Workflow` and runs it.

A Flow has three supported authoring forms. The module DSL, map-based data
definitions through `Jido.Flow.new/1`, and stored JSON through
`Jido.Flow.Codec` must all produce the same canonical `%Jido.Flow{}` model.
Changes to one form must keep equivalent behavior in the other forms.

`Jido.Exec` compiles Actions and Flows to Runic workflows and projects Runic
results to the Jido result contract. Runic owns readiness, scheduling, retry
and timeout policy, events, persistence, and resume. `Jido.Exec.run/4` runs to
completion in memory. `Jido.Exec.start/6`, `step/2`, `resume/4`, and
`result/1` use a supervised `Runic.Runner` for managed, stepwise, and durable
execution. Jido adds no scheduler, cursor, checkpoint format, or async handle.
Queues, distributed coordination, effect delivery, and exactly-once policy
belong to a higher-level runtime.

Read these files before a change that affects their subject:

- `README.md` for the supported product surface.
- `usage-rules.md` for the public use rules.
- `guides/actions.md`, `guides/flows.md`, and `guides/execution.md` for the main
  contracts.
- `guides/testing.md` for test patterns.
- `guides/v2-to-v3-migration.md` for version 2 to version 3 breaking changes.

## Source Map

- `lib/jido_action.ex` contains the Action behavior and `use Jido.Action`.
- `lib/jido_instruction.ex` contains the executable call frame.
- `lib/jido_flow.ex` is the public Flow facade.
- `lib/jido_flow/dsl/` contains compile-time authoring and lowering.
- `lib/jido_flow/definition.ex` normalizes map-based component definitions.
- `lib/jido_flow/codec.ex` and `lib/jido_flow/registry.ex` contain the
  versioned stored-JSON boundary.
- `lib/jido_exec/compiler.ex` converts canonical Flow data to a Runic workflow.
- `lib/jido_exec.ex` is the public execution facade.
- `lib/jido_exec/node/` contains the executable Runic components. Runner
  integration is in `lib/jido_exec/runner/`.
- `test/support/` contains shared Actions and Flow fixtures.

Compiler, codec, node, and runner modules are internal.
Do not make an internal module public only to make a test easy. Test through a
public boundary unless the internal rule itself needs a focused unit test.

## Required Workflow

Use test-driven development for each behavior change:

1. Run the nearest existing tests and record the baseline.
2. Add a small regression test that fails for the correct reason.
3. Make the smallest implementation change that makes it pass.
4. Run the focused test file again.
5. Run the full default suite and the applicable quality checks.

Do not change production code when the task asks only for analysis or review.
Keep unrelated user changes in the worktree. Do not rewrite or remove them.

Run these commands from the package root:

```text
mix test path/to/test_file.exs
mix test
mix format --check-formatted
MIX_ENV=test mix compile --warnings-as-errors
mix credo --min-priority high
mix dialyzer
mix docs --warnings-as-errors
mix test --cover --warnings-as-errors
```

`mix test` excludes tests tagged `:integration`, `:flaky`, and `:skip`, and
the opt-in suites. Run the opt-in suites after a compiler, Flow, or Exec
change:

```text
mix test.authoring
mix test.property
mix test.system
mix test.load
mix test.fuzz
```

Run `mix quality` when a broad change is ready. It runs the formatter check,
compilation with warnings as errors, Doctor, ExDoc, Credo, and Dialyzer.
Doctor requires 100 percent module, function, and spec documentation
coverage.

If the full suite fails but the focused test passes, investigate shared state,
mailbox use, registered process names, telemetry handlers, and scheduler load.
Do not dismiss the failure only because a second run passes.

## Test Rules

Keep tests deterministic and observable through values or explicit messages.

- Do not use `Process.sleep/1` or elapsed time as synchronization.
- Use monitors, unique references, and explicit ready and release messages.
  For managed execution, use Runic worker hooks or the `on_complete:` callback.
- Use `start_supervised!/1` for owned OTP processes, including test Runners.
  Give each Runner and execution a unique name or ID.
- Stop tasks and helper processes in the test or in `on_exit/1`.
- Use a confirmed barrier before an absence assertion. Prefer
  `refute_received/1` after the barrier to a short timed wait.
- Do not use Logger output as the only result assertion. Runic logs a warning
  for each failed runnable; capture logs in tests that expect failures.
- Use unique telemetry handler IDs and detach each handler in `on_exit/1`.
- Do not depend on task completion order. Assert canonical result order.
- Set `async: false` when a test changes global or registered state.

Test the public boundary and the local rule. For example, test an Action
callback directly for its business rule, and test it through `Jido.Exec.run/4`
for validation, return normalization, and error behavior.

## Rules That Must Stay True

### Actions And Instructions

- An Action callback returns `{:ok, result}`, `{:ok, result, effects}`,
  `{:error, reason}`, or `{:error, reason, effects}`.
- Only a Dispatch expander can return `{:continue, input, target}`. It selects
  the next Action or Flow for that Dispatch. A root Action and other Flow
  positions reject a continuation.
- A normal success result is a map. Other intentional success values use
  `Jido.Action.Output`.
- Input validation runs before the callback. Output validation runs after it.
- Raises, throws, exits, invalid callback returns, and invalid validator
  returns become structured `Jido.Action.Error` structs at `Jido.Exec`.
- Preserve useful original failure data and stacktraces in the documented
  error fields. Do not expose internal wrapper shapes as a new contract.
- An Instruction contains one Action or Flow target, params, context, and
  caller metadata. Do not put Flow structure or runtime policy in it.
  Resolution reads the currently loaded module every time.

### Flows

- `Jido.Flow.new/1` owns validation for data definitions. Raw struct literals
  can show the canonical shape.
- The DSL, data definitions, and the Codec reader must use the same validation
  rules.
- Node names and semantic output must not depend on map enumeration, task
  completion, or scheduler order.
- Source order does not create a dependency. Result references and `needs:`
  create dependencies.
- Canonical Flow data, the module DSL, data definitions, and Codec require an
  explicit, non-nil `output`. In the module DSL, `output` must be the
  final declaration. Do not infer output from source order or graph terminal
  nodes, and do not add a `return` alias.
- Use `{:ok, output, requests}` for deferred effects.
  Flow collects explicit effects from all successful executed components.
  Canonical dependency order and component names define effect order; nested
  Flows occupy their parent position. Collections use input or iteration order.
- The third success element is an optional proper list of effect requests.
  Put metadata in output. Failed, timed-out, or cancelled
  executions return no executable effect batch. Exec never dispatches effects.
- Stored-map encoding must be deterministic and versioned. Decoding must use
  `Jido.Flow.Registry` and must return structured validation errors.
- Do not create atoms from runtime Flow input. Registry lookups must resolve
  only the host values that already exist.
- `Jido.Flow.validate/1` is inert. `Jido.Exec.compile/2` also checks target
  contracts. Neither function runs Action work.

### Execution And OTP

- Runic owns scheduling, readiness, retry and timeout policy, events,
  persistence, and resume. Do not add a Jido scheduler, cursor, checkpoint
  format, async handle, or continuation loop. Use public Runic protocols.
- `Jido.Exec.run/4` runs in an unlinked task under the selected Task
  Supervisor. Caller exit stops the task and its linked work. An Action crash
  does not exit the caller. Helper processes must exit with the task.
- Run-to-completion, stepwise, and durable execution must use the same Flow
  semantics and return the same final value and effects.
- `timeout:` is a per-attempt Runic timeout. `max_attempts:` retries only
  errors that `Jido.Action.Error.retryable?/1` accepts.
- A halting failure stops new dispatch. Work that already started can finish.
  The reported error must not depend on `max_concurrency`.
- Results, failure selection, item IDs, and effect order must not depend on
  scheduler or task completion order.
- Fact values must stay linear in collection size. Do not copy the Flow frame
  into every collection item or loop iteration.
- Runic does not persist runtime context or runtime policy. `resume/4` must
  supply them again. Do not compile context into stored workflow components.
- Managed execution rejects non-portable params, context, metadata, outputs,
  and effects.
- Telemetry handlers run synchronously. Each started Jido span must stop when
  Exec returns.

### Telemetry And Errors

- Jido emits `[:jido, :action, ...]` spans per Action attempt and
  `[:jido, :flow, ...]` spans for immediate Flow runs. Runic owns runtime
  telemetry. Keep event names, measurements, metadata keys, and nesting
  stable. Start and stop metadata must not include params, context, results,
  or full errors.
- Public failures return exception structs. Keep `to_map/1` deterministic.
- Do not change error types, matchable messages, detail keys, or retry
  classification without contract tests and documentation updates.

## Documentation

Treat every documented module, function, struct, type, option, return tuple,
error, telemetry event, and stored-map field as a public contract. Before a
change, search the README, guides, usage rules, tests, and changelog for the
current form.

### Where Documentation Lives

| File | Audience | Content |
| --- | --- | --- |
| `README.md` | New users | Pitch, install, quick tour, mental model, next steps |
| `usage-rules.md` | Coding agents that use the package | Short, imperative rules for the current public API |
| `AGENTS.md` | Contributors and agents that change the package | This file |
| `guides/` | Users | Tutorials (`.livemd`), concepts, how-to guides, and reference |
| Module docs | Users | The API reference |
| `CHANGELOG.md` | Users | Release history; `git_ops` manages released entries |

The ExDoc sidebar groups and module groups live in `mix.exs`. Add every new
guide to `extras` and `groups_for_extras`.

### Rules

- Give each fact one home. Link to it from other pages instead of repeating
  it. Effects live in `guides/action-effects.livemd`, Exec options in
  `guides/execution.md`, managed options in `guides/managed-execution.md`,
  and errors in `guides/errors.md`.
- Show a runnable example first, then the rules.
- Every `elixir` code block must run against the current source, or be an
  obvious fragment. Run changed examples before you commit.
- Use one install version, the `@version` in `mix.exs`. Do not add
  "requires beta N" notes; history belongs in the CHANGELOG and the migration
  guide.
- Use relative links between guides. Write DSL calls without parentheses, as
  the formatter does.
- Keep Runic internals and canonical node shapes out of introductory guides.
- Add `@spec` and `@typedoc` for public data and functions. Add
  `@moduledoc false` or `@doc false` for internal surfaces.
- Do not document a feature before tests establish its exact behavior.

### Guide-Backed Tests

Some tests read guides directly. Keep them passing:

- `test/jido_flow/dsl/spark_surface_test.exs` evaluates `elixir` blocks by
  index in `flow-steps.livemd`, `flow-choices.livemd`,
  `flow-collections.livemd`, `flow-iterate-state.livemd`, and
  `dynamic-flows.md`. It also checks that the `Jido.Flow` DSL reference links
  to those guides. Do not rename those files or reorder their tested blocks
  without updating the test.
- `test/examples/action_effects_test.exs` evaluates every block in
  `action-effects.livemd`.
- `test/property/support/report.exs` parses contract IDs from the
  `guides/public-contracts.md` tables.

## Runtime And Dependencies

- Test Erlang/OTP 27, 28, and 29 with the shared compatibility matrix.
- Support Elixir 1.18 and later. The Mix requirement is `~> 1.18`.
- The direct production dependencies are `telemetry`, `zoi`, `jason`, `runic`,
  `splode`, and `spark`. Runic uses the integration fork during v3
  development; restore a normal Hex requirement before a Hex release.
- Do not add a direct production dependency without an explicit request and a
  clear package-boundary reason.
- Keep development and test dependencies limited to normal build, analysis,
  documentation, and test work.
