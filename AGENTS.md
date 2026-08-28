# AGENTS.md

## Scope

These instructions apply to the `jido_action` package.

This branch contains the Jido Action v3 beta. Treat this package
as foundational code for the Jido ecosystem. Correct behavior, deterministic
results, process cleanup, clear errors, and a stable public API have priority
over fast changes.

Do not treat this code as a disposable spike. Do not restore v2 behavior or add
a compatibility layer unless the user asks for it.

## Package Boundary

The package has four main public parts:

- `Jido.Action` defines one named and validated unit of work.
- `Jido.Instruction` is data for one Action or Flow call.
- `Jido.Flow` defines a validated, in-memory graph of Action calls.
- `Jido.Exec` is the public execution and error boundary.

A Flow has four supported authoring forms. The module DSL,
`Jido.Flow.Builder`, stored JSON through `Jido.Flow.Codec`, and direct
constructors must all produce the same canonical `%Jido.Flow{}` model.
Changes to one form must keep equivalent behavior in the other forms.

`Jido.Exec` owns one in-memory execution session. It supports synchronous and
asynchronous run-to-completion execution and step-wise Flow execution. An
asynchronous handle supports owner-bound wait and cancellation. It does not
provide durable orchestration. Persistence, queues, retries, durable
cancellation policy, recovery, distributed coordination, and deployment-safe
continuation belong to a higher-level runtime. `Jido.Exec.run/4` can apply one
finite timeout to the complete call.

Read these files before a change that affects their subject:

- `README.md` for the supported product surface.
- `usage-rules.md` for the public use rules.
- `guides/actions.md`, `guides/flows.md`, and `guides/execution.md` for the main
  contracts.
- `guides/testing.md` for test patterns.
- `guides/v3-migration.md` for intentional breaking changes.

## Source Map

- `lib/jido_action.ex` contains the Action behavior and `use Jido.Action`.
- `lib/jido_instruction.ex` contains the executable call frame.
- `lib/jido_flow.ex` is the public Flow facade.
- `lib/jido_flow/dsl/` contains compile-time authoring and lowering.
- `lib/jido_flow/builder.ex` contains runtime authoring normalization.
- `lib/jido_flow/codec.ex` and `lib/jido_flow/registry.ex` contain the
  versioned stored-JSON boundary.
- `lib/jido_flow/compiler/` converts canonical Flow data for execution.
- `lib/jido_exec.ex` is the public execution facade.
- `lib/jido_exec/` contains execution state, scheduling, guards, limits, and
  failure handling.
- `test/support/` contains shared Actions and Flow fixtures.

Compiler, codec, graph-adapter, scheduler, and guard modules are internal.
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

Use these commands from the package root:

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

`mix test` excludes tests tagged `:integration`, `:flaky`, and `:skip`.

Run `mix quality` when a broad implementation change is ready. It runs the
formatter check, compilation with warnings as errors, Doctor, ExDoc, Credo,
and Dialyzer. Build the docs when a public module, type, option, result, or
error changes.

If the full suite fails but the focused test passes, investigate shared state,
mailbox use, registered process names, telemetry handlers, and scheduler load.
Do not dismiss the failure only because a second run passes.

## Test Rules

Keep tests deterministic and observable through values or explicit messages.

- Do not use `Process.sleep/1` or elapsed time as synchronization.
- Use monitors, unique references, and explicit ready/release messages.
- Use `start_supervised!/1` for owned OTP processes when practical.
- Stop tasks and helper processes in the test or in `on_exit/1`.
- Use a confirmed barrier before an absence assertion. Prefer
  `refute_received/1` after the barrier to a short timed wait.
- Do not use Logger output as the only result assertion.
- Use unique telemetry handler IDs and detach each handler in `on_exit/1`.
- Do not depend on task completion order. Assert canonical result order.
- Set `async: false` when a test changes global or registered state.
- Use `async: true` only when the test and all fixtures are isolated.

For concurrent execution tests, make each worker announce that it is ready.
Release workers with explicit messages. Monitor workers and callers when exit
behavior matters. Assert results, process termination, resource release, and
unexpected mailbox messages where applicable.

Test the public boundary and the local rule. For example, test an Action
callback directly for its business rule, and test it through `Jido.Exec.run/4`
for validation, return normalization, and error behavior.

## Rules That Must Stay True

### Actions And Instructions

- An Action callback returns `{:ok, result}`, `{:ok, result, extra}`,
  `{:error, reason}`, or `{:error, reason, extra}`.
- A normal success result is a map. Other intentional success values use
  `Jido.Action.Output`.
- Input validation runs before the callback. Normal output validation runs
  after the callback.
- Exceptions, throws, exits, invalid callback returns, and invalid validator
  returns must become the documented structured errors at `Jido.Exec`.
- Preserve useful original failure data and stacktraces in the documented
  error fields. Do not expose internal wrapper shapes as a new contract.
- An Instruction contains one Action or Flow target, params, context, and
  caller metadata. Do not put Flow structure or runtime policy in it.

### Flows

- Direct Flow and component constructors are a supported Flow authoring API.
  Raw struct literals can show the canonical shape, but constructors own
  validation.
- The DSL, Builder, Codec reader, and direct constructors must use the same
  validation rules.
- Node names and semantic output must not depend on map enumeration, task
  completion, or scheduler order.
- Source order does not create a dependency. Result references and `after:`
  create dependencies.
- Every Flow must declare its `output`. Do not infer an output from terminal
  nodes and do not add a `return` alias.
- A Flow discards the extra value from a three-item Action return.
- Stored-map encoding must be deterministic and versioned. Decoding must use
  `Jido.Flow.Registry` and must return structured validation errors.
- Do not create atoms from runtime Flow input. Registry lookups must resolve
  only the host values that already exist.
- `validate/1` is inert. `validate_executable/1` also checks target contracts.
  Neither function runs Action work.

### Execution And OTP

- Run-to-completion and step-wise execution must use the same Flow semantics
  and return the same final value.
- A step or wave must consume one execution revision. Reuse or concurrent use
  of an old execution must fail before Action work starts.
- If a caller stops during a mutation, a later call must not repeat work whose
  commit state is unknown.
- A node failure stops new dispatch. Work that already started can finish.
- Failure lists and node results use canonical node order.
- `max_concurrency` applies across one execution, including nested Flows and
  collection work. Reduce and Iterate work stays serial.
- Helper processes must have clear owners. Monitor owners and release permits,
  task slots, registrations, and telemetry spans on all terminal paths.
- Do not leave stale registered processes, active Tasks, monitors, or messages
  after success, error, exit, or caller interruption.
- Keep `timeout:` as one complete-call limit for `Jido.Exec.run/4` and
  `Jido.Exec.run_async/4`. Keep async cancellation owner-bound and in-memory.
  Do not add automatic retry, per-runnable deadlines, durable cancellation,
  rewind, or persistence without an explicit public API decision.

### Telemetry And Errors

- Keep one execution ID across nested work.
- Each started lifecycle must have one stop or error event when Jido reaches a
  terminal result.
- Keep documented event names, measurements, metadata keys, and nesting
  stable. High-volume collection events must stay opt-in for consumers.
- Public failures return exception structs. Keep `Jido.Action.Error.to_map/1`
  deterministic and suitable for external data.
- Do not change error types, messages that callers can match, detail keys, or
  retry rules without contract tests and documentation updates.

## Public API And Documentation

Treat every documented module, function, struct, type, option, return tuple,
error, telemetry event, and stored-map field as a public contract. Before a
change, search the README, guides, usage rules, tests, and changelog for the
current form.

Add `@spec` and `@typedoc` for public data and functions. Add `@moduledoc false`
or `@doc false` for internal surfaces. Update examples and migration notes when
behavior changes. Do not document a feature before tests establish its exact
behavior.

## Runtime And Dependencies

- Test Erlang/OTP 27, 28, and 29 with the shared v2 compatibility matrix.
- Support Elixir 1.18 and later. The Mix requirement is `~> 1.18`.
- The intended direct production dependencies are `telemetry`, `zoi`, `runic`,
  `splode`, and `spark`.
- Do not add a direct production dependency without an explicit request and a
  clear package-boundary reason.
- Keep development and test dependencies limited to normal build, analysis,
  documentation, and test work.
