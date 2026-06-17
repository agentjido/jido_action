# Jido Runic Exec Plan

## Intent

Use Runic as the execution engine while keeping Jido's public model small,
consistent, and functional.

The target concepts are:

- `Jido.Action` - validated leaf contract.
- `Jido.Instruction` - data form of one action invocation.
- `Jido.Flow` - Jido-native composition value backed by Runic workflow state.
- `Jido.Exec` - execution facade for actions, instructions, and flows.

Runic should remain powerful and visible through advanced options and native
components, but Runic-specific bridge modules should not become separate public
Jido concepts.

## Functional Definitions

- `invoke` - call one action once.
- `attempt` - execute one Runic runnable attempt.
- `step` - perform one Runic prepare/dispatch/apply cycle.
- `run` - repeat steps until quiescence, error, halt, or bound.
- `resume` - continue an existing workflow with new input.

These terms should guide function names, docs, telemetry, and tests.

## Target Public Surface

```elixir
Jido.Exec.run(action, params, context, opts)
Jido.Exec.run(%Jido.Instruction{}, opts)
Jido.Exec.run(%Jido.Flow{}, input, opts)

Jido.Exec.step(flow_or_workflow, input \\ nil, opts \\ [])
Jido.Exec.resume(workflow, input, opts)
Jido.Exec.results(result_or_workflow, opts)
Jido.Exec.events(result_or_workflow, opts)
Jido.Exec.summary(result_or_workflow)
Jido.Exec.provenance(result_or_workflow, fact_hash)
```

Runner lifecycle should be explicit if exposed:

```elixir
Jido.Exec.Runner.start_link(opts)
```

Avoid `Jido.Exec.start_link/1` unless `Jido.Exec` itself becomes the supervised
execution engine process.

## Result Shape

Introduce a Jido result value instead of returning raw Runic workflow state from
every facade function:

```elixir
%Jido.Exec.Result{
  workflow: workflow,
  status: :ok | :error | :halted | :max_cycles,
  results: results,
  events: events,
  cycles: cycles,
  error: error
}
```

The result should expose the underlying workflow for advanced Runic usage while
giving Jido a stable return shape for documentation and compatibility.

## Responsibility Boundaries

### Jido Owns

- Action module contract.
- Zoi input validation.
- Zoi output validation.
- Jido return shape normalization.
- Jido error structs.
- Jido telemetry metadata.
- `Jido.Instruction` normalization.
- Jido-facing flow construction.

### Runic Owns

- Workflow graph state.
- Runnable prepare/execute/apply mechanics.
- Dependency activation.
- Joins, fan-in, stateful components, and state machines.
- Scheduler policies.
- Runnable retry and timeout.
- Fallbacks and failure modes.
- Runner dispatch, stores, checkpointing, and durable events.

### Jido.Exec Owns

- Translating Jido executable values into Runic execution.
- Translating Jido options into Runic scheduler policies.
- Driving step/run/resume semantics.
- Returning Jido-shaped execution results.
- Preserving backwards-compatible single-action execution APIs.

## Policy Ownership

Long term, Runic should own retry and timeout policy.

The current single-action `Jido.Exec` retry/timeout loop should be replaced by a
one-shot action invocation called from Runic runnable execution.

Target behavior:

```text
Runic retries the runnable.
Jido invokes the action once per runnable attempt.
```

Avoid this double policy stack:

```text
Runic retries N times * Jido.Exec retries M times
```

## One-Shot Action Invocation

Extract the current leaf-action execution logic into an internal function:

```elixir
invoke_action_once(action, params, context, opts)
```

It owns:

- normalize params and context
- validate action module
- validate params
- call `run/2`
- validate output
- normalize return shape
- normalize exceptions
- emit Jido action telemetry

It must not own:

- retry
- timeout
- async orchestration
- flow stepping
- runner lifecycle

`Jido.Flow.Step` should call this one-shot invocation, not the full public
`Jido.Exec.run/4` facade.

## Option Translation

Backwards-compatible action options should translate into Runic policy:

```elixir
timeout: 5_000
max_retries: 2
backoff: 250
```

becomes a default scheduler policy for Jido flow steps.

Policy precedence should be explicit:

```text
step opts > flow scheduler policies > flow step opts > app config defaults
```

This precedence needs tests.

## Introspection Placement

Remove separate public `Jido.Runic.Introspection`.

Static flow introspection belongs on `Jido.Flow`:

```elixir
Jido.Flow.components(flow)
Jido.Flow.node_map(flow)
Jido.Flow.graph(flow)
```

Runtime introspection belongs on `Jido.Exec` or `Jido.Exec.Result`:

```elixir
Jido.Exec.results(result_or_workflow)
Jido.Exec.events(result_or_workflow)
Jido.Exec.summary(result_or_workflow)
Jido.Exec.provenance(result_or_workflow, fact_hash)
```

## Runnable Execution Placement

Remove separate public `Jido.Runic.RunnableExecution`.

Use Runic's `PolicyDriver` from `Jido.Exec.step/3` so runnable retry, timeout,
fallback, and durable events are all handled by Runic.

Any remaining crash normalization should be private to `Jido.Exec` or handled by
Runic policy execution.

## Non-Determinism

`Jido.Exec` should expose non-determinism instead of hiding it.

A step is:

```text
workflow_state + input/event + execution_policy
  -> runnable_set
  -> executed_runnables
  -> events
  -> new_workflow_state
```

The guarantee:

```text
Exec deterministically applies known runnable results to workflow state.
Exec does not make concurrent work, external I/O, retries, timeouts, or LLM calls deterministic.
```

For non-deterministic flows, the durable record is workflow state, runnable
events, and produced facts.

## Async And Runner

`Jido.Exec.run_async/4`, `await/1,2`, and `cancel/1` can remain for
single-action compatibility.

The preferred async and managed execution path for flows should be Runner-backed:

```elixir
Jido.Exec.Runner.start_link(opts)
Jido.Exec.start_flow(runner, flow_id, flow, opts)
Jido.Exec.resume(runner, flow_id, input, opts)
Jido.Exec.results(runner, flow_id, opts)
Jido.Exec.checkpoint(runner, flow_id)
Jido.Exec.stop(runner, flow_id, opts)
```

This keeps the process boundary explicit while keeping `Jido.Exec` as the
execution facade.

## Migration Plan

1. Move flow execution facade behavior from `Jido.Runtime` into `Jido.Exec`.
2. Add `Jido.Exec.Result`.
3. Extract one-shot action invocation from the current `Jido.Exec.run/4`.
4. Change `Jido.Flow.Step` to invoke actions once instead of calling the full
   public `Jido.Exec.run/4`.
5. Translate legacy `timeout`, `max_retries`, and `backoff` options into Runic
   scheduler policies.
6. Replace the custom runnable execution helper with Runic `PolicyDriver`.
7. Fold static introspection into `Jido.Flow`.
8. Fold runtime introspection into `Jido.Exec` or `Jido.Exec.Result`.
9. Introduce explicit runner lifecycle under `Jido.Exec.Runner` if needed.
10. Deprecate or remove `Jido.Runtime`.
11. Update README, usage rules, and guides around the final four concepts:
    `Action`, `Instruction`, `Flow`, and `Exec`.

## Suggested Commit Order

1. `refactor: move flow execution facade into jido exec`
2. `feat: add jido exec result`
3. `refactor: extract one-shot action invocation`
4. `refactor: execute flow steps through one-shot invocation`
5. `refactor: translate exec policy options to runic policies`
6. `refactor: replace runnable execution helper with runic policy driver`
7. `refactor: fold runic introspection into flow and exec`
8. `docs: document runic-powered exec architecture`

## End State

```text
Jido.Action       leaf contract
Jido.Instruction  invocation data
Jido.Flow         composition and workflow state
Jido.Exec         Runic-powered execution facade
Runic             execution engine underneath
```

Guiding rule:

```text
Jido names the domain.
Runic powers execution.
Exec is the bridge.
```
