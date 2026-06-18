# Jido Runic Exec Status

This note records the current execution architecture after the Runic refactor.
The purpose is to keep `jido_action` from regrowing a second runtime beside
Runic.

## Current Shape

`Jido.Exec` is a Runic-backed facade for flows and raw workflows. It is not a
direct action runtime.

It accepts:

- `%Jido.Flow{}`
- `%Runic.Workflow{}`

It returns:

- `{:ok, %Jido.Exec.Result{}}`
- `{:error, %Jido.Exec.Result{}}`
- `{:error, exception}` for validation errors before Runic execution starts

The facade surface is intentionally small:

- `run/1`, `run/2`, and `run/3` execute a flow or workflow to quiescence.
- `step/1` advances an existing workflow once without new input.
- `step/3` advances once with explicit input and Runic options.
- `resume/2` and `resume/3` continue a flow or workflow with new input.
- `results/1-2`, `events/1-2`, `summary/1`, and `provenance/2` are thin
  Jido projections over Runic workflow state.

`Jido.Exec.run/2` now treats its second argument as input, including keyword
lists. Runtime options require `run/3`.

```elixir
Jido.Exec.run(flow, [value: 1])
Jido.Exec.run(flow, %{value: 1}, scheduler_policies: [{:step, %{max_retries: 1}}])
```

`Jido.Exec` uses Hex `runic` public APIs. It does not require the local Runic
PR that added `Runic.Workflow.RunResult` or `Runic.Workflow.PolicyProvider`.

The only module left under `lib/jido_action/exec/` is `Jido.Exec.Result`.

## Boundary Model

The intended ownership is:

- `Jido.Action`: defines one leaf action contract.
- `Jido.Instruction`: describes one action call frame: action, params, context.
- `Jido.Flow.Step`: adapts one instruction into a Runic component.
- `Jido.Flow`: composes Jido action steps and native Runic components.
- `Jido.Exec`: runs flows/workflows through Runic and projects results.
- Runic: owns scheduling, retries, timeouts, fallback, stepping, durable
  execution, managed runners, and runtime policy.

Raw action execution remains the action module's own contract:

```elixir
{:ok, params} = MyAction.validate_params(params)
{:ok, output} = MyAction.run(params, context)
{:ok, output} = MyAction.validate_output(output)
```

That path has no Jido-owned retry, timeout, async, telemetry, supervision, or
runtime policy.

## Implemented Cuts

The following old runtime pieces have been removed:

- direct action `Jido.Exec.run/4`
- async `run_async/await/cancel`
- action-level retry and timeout wrappers
- action execution telemetry
- context propagator behaviours and no-op propagators
- task supervisors
- execution validator/helper modules
- `Jido.Exec.Introspection`
- `Jido.Action.Invoke`

The old policy-shaped option slots were also removed:

- `Jido.Instruction.opts`
- `Jido.Flow.Step.exec_opts`
- `Jido.Flow.Step.scheduler_policy`

`Jido.Exec.Result.status` now reflects current local Runic statuses only:

```elixir
:ok | :error | :max_cycles
```

## Flow Step Invocation

`Jido.Flow.Step` contains the only action invocation adapter.

It does:

- validate that the action module is loaded and implements the Jido action
  surface
- merge static step params with the incoming Runic fact value
- merge static step context with Runic `run_context`
- call `validate_params/1`
- call `run/2`
- validate successful output with `validate_output/1`
- normalize exceptions, exits, throws, invalid return shapes, and action error
  reasons into Jido errors

It does not do:

- retry
- timeout
- async
- telemetry
- supervision
- cancellation
- fallback

Those remain Runic policy concerns. This is the key rule: the step adapter may
perform one action attempt, but it must not become an action runtime.

## Directives

Actions may return three-tuples:

```elixir
{:ok, result, directives}
{:error, reason, directives}
```

The data plane remains the validated action result. Directives are preserved as
control-plane metadata.

Successful directive flow:

- `validate_output/1` validates `result`
- the produced Runic fact value is `result`
- directives are stored in fact/event metadata
- `Jido.Exec.Result.directives` projects them as flat entries

Failed directive flow:

- the runnable fails with the normalized action error
- directives are attached to the normalized error details
- `Jido.Exec.Result.directives` exposes them without executing them

Current projection shape:

```elixir
%Jido.Exec.Result{
  directives: [
    %{step: :send_email, status: :ok, fact_hash: fact_hash, directives: directives}
  ]
}
```

`jido_action` preserves directives; it does not interpret or execute them.

## Single Action Sugar

Direct actions are not accepted by `Jido.Exec`.

The supported ergonomic path is explicit one-step flow construction:

```elixir
flow = Jido.Flow.single(MyAction, %{value: 1}, context: %{tenant_id: "t1"})
{:ok, result} = Jido.Exec.run(flow, %{})
```

`Jido.Flow.from_action/3` and `Jido.Flow.single/3` compile an action module or
`%Jido.Instruction{}` into a one-step Runic workflow. The return shape stays
`%Jido.Exec.Result{}` because execution still goes through Runic.

This avoids reviving the old direct action tuple API while keeping the useful
"run one action through policy" ergonomics available.

## Runtime Policy

Runic owns retry, timeout, fallback, scheduling, durable execution, and managed
runner behavior.

Jido can provide policy to Runic through:

- `Jido.Flow.policy/3`, keyed by component name, type, or Runic matcher
- workflow scheduler policies on the underlying `%Runic.Workflow{}`
- runtime `:scheduler_policies` passed to `Jido.Exec.run/3` or `step/3`

The tested precedence is:

1. Runic defaults
2. named flow/workflow scheduler policy
3. runtime `:scheduler_policies`

The important proof is that `Jido.Flow.Step` participates in Runic policy:

- retry policy retries failed action attempts
- timeout policy interrupts a blocking action attempt and returns a failed
  runnable instead of hanging the caller

Zack's Runic PR feedback reinforced this boundary: scheduling/runtime policy
belongs outside functional components. `Jido.Flow.Step` is named so external
Runic policy can match it; it does not expose a component-owned policy provider.

## Remaining Sharp Edges

### Jido Owns Result Projection

Hex Runic returns updated workflows from `react/3` and
`react_until_satisfied/3`, not structured run results. To keep relying on Hex,
`Jido.Exec` runs a narrow public-API loop:

- prepare runnables through `Runic.Workflow.prepare_for_dispatch/1`
- execute each runnable through `Runic.Workflow.PolicyDriver`
- apply results with `Runic.Workflow.apply_runnable/2`
- project status, errors, cycles, events, and directives into
  `Jido.Exec.Result`

This is not a second scheduler. Runic still owns runnable policy execution. The
risk is that Jido's loop could drift from Runic's own `react/3` semantics if
Runic changes its dispatch/apply contract.

### Flow Step Is A Small But Important Boundary

The action invocation code now lives in `Jido.Flow.Step`. That is simpler than a
separate internal invoke module, but it also concentrates several concerns in
one file: schema, Runic protocols, port derivation, and one-attempt invocation.

This is acceptable only while the invocation code stays policy-free. If retry,
timeout, async, telemetry, fallback, or cancellation reappears here, the old
runtime is coming back under a new name.

### Directives Need A Downstream Owner

The current design preserves directives but does not define their semantics.
That is the right boundary for this package, but another package or layer must
decide what a directive means.

Open questions for that layer:

- Are directives ordered globally, per step, or per fact?
- Are directives durable events, signals, instructions, or agent commands?
- Should failed-step directives be visible to fallback handlers?
- Should directives be typed structs instead of arbitrary terms?

Until those answers exist, `Jido.Exec.Result.directives` should remain a
projection, not a command bus.

### Context Is Still A Thin Map

`Jido.Instruction.context`, `Jido.Flow.Step.context`, and Runic `run_context`
are merged into one action context map.

That is pragmatic, but it is not a rich context propagation model. If tracing,
tenancy, cancellation, deadlines, or security boundaries become first-class
runtime concerns, prefer Runic-owned context/deadline mechanisms over adding
another Jido propagator layer.

### Managed Runner APIs Stay In Runic

`Jido.Exec` is local execution sugar. Managed lifecycle APIs should stay on
Runic unless Jido has a concrete domain projection to add.

The current guidance is:

- use `Jido.Flow` to build the workflow
- use `Jido.Exec` for local execution and result projection
- use `Runic.Runner` directly for managed workflow lifecycle

### Flow Script Is Still Experimental

`Jido.Flow.Script` is an untrusted-input parser spike. It compiles restricted
Elixir-shaped syntax into `Jido.Flow`; it does not evaluate, compile,
macro-expand, or invoke user code.

It should remain separate from the execution refactor until the IR and control
flow model are settled.

## Non-Goals

- Reintroducing direct action tuple-compatible `Jido.Exec.run/4`.
- Reintroducing `run_async/await/cancel`.
- Recreating action-level retry/timeout outside Runic.
- Reintroducing context propagator behaviours in `jido_action`.
- Treating `jido_action` as an agent runtime.
- Promoting a public action invocation API.
- Adding tuple-compatible shims for the old direct action `Jido.Exec` API.
- Treating action directives as workflow data-plane values.

## Verification

The refactor is covered by focused tests for:

- flow and raw Runic workflow facade dispatch
- rejection of direct action execution through `Jido.Exec`
- one-step flow sugar
- three-tuple directive preservation for success and error paths
- Runic retry policy over `Jido.Flow.Step`
- Runic timeout policy over `Jido.Flow.Step`
- max-cycle errors
- result schema validation
- policy precedence
- flow script compilation

The strongest regression tests are:

- `test/jido_action/runtime_test.exs`
- `test/jido_action/flow_step_test.exs`
- `test/jido_action/exec_facade_test.exs`
