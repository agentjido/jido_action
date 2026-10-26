# Flow Waits

```elixir
defmodule ApprovalFlow do
  use Jido.Flow, name: "approval"

  flow do
    selection "decision" do
      await "approved", event: "order.approved", match: %{order_id: input(:order_id)}
      await "rejected", event: "order.rejected"
      timer "expired", after_ms: 7_776_000_000
    end

    output result("decision")
  end
end

{:ok, _validated} = Jido.Flow.validate(ApprovalFlow.flow())
{:ok, _workflow} = Jido.Exec.compile(ApprovalFlow)
{:error, %{details: %{reason: :unsupported_host, capability: :waits}}} =
  Jido.Exec.run(ApprovalFlow, %{order_id: "order-1"})
```

Wait definitions, validation, and compilation are implemented.
`Jido.Exec.Waits` provides shared wait operations for execution hosts.
Normal `Jido.Exec.run/4` and `start/6` reject static waits before Action work.
Invoke checks a selected Flow before any Action in that child graph runs.
Its decision and expander have already run
to select the target. Do not use the test driver as an AgentServer runtime.

An Action can call `Jido.Exec.supports?(context, :waits)` when its decision
must depend on the execution host. The context comes from the Action callback.
An ordinary Exec run returns `false`. A wait host returns `true`.
The input must be a map. A missing key, an unknown capability, or a malformed
capability list returns `false`. The key `:jido_exec_capabilities` is reserved:
Exec removes caller and bound values, and only the current host can add it.

## One Wait Model

The DSL, map definitions, and Codec produce one canonical `:wait` component.
Map definitions use `kind: :timer`, `:await`, or `:selection`. A Selection has
a list of named timer and event options. Each authoring kind requires its own
fields. Keep explicit dependencies and output. Match references create data
dependencies. Source order does not create dependencies.

Timers use non-negative millisecond delays without a 32-bit timer limit.
Events match exact payload key/value pairs. A Selection contains timers and
events. It does not race Actions.

The timer result is `%{fired_at: absolute_deadline}`. An event result
is its accepted payload. A multi-option Selection returns `selected`, `value`,
`accepted_at`, and `input_id` (nil for a timer). A one-option Selection has the
same result as its sole wait. The shared wait operations define these result
shapes for all hosts. Normal Exec still rejects waits.

## Tested Recovery Behavior

The [test driver](https://github.com/agentjido/jido_action/blob/release/v3/test/support/wait_host.ex)
and its ETS Store are test support. They are excluded from the library build.
They provide a controlled clock and synchronous native snapshot transitions
for the package tests. They do not establish a second public Exec lifecycle.
Action work uses the same protected task boundary as immediate Exec.

The test driver supports these behaviors:

- A 90-day timer stores one absolute deadline. No worker, timer, or Action
  task remains active while that snapshot waits. Restore retains the deadline.
- Input uses a stable non-empty ID and an active occurrence ID, or an early
  static path that has not opened. Equal retries are inert. Conflicting IDs,
  stale occurrences, and expired input fail.
- Unmatched active input is rejected. Useful early input has a bounded buffer.
  A full early buffer cannot prevent an active matching event from resolving.
- The earliest accepted input or timer deadline wins. Timers win exact-time
  ties. Receipt order and then option order break remaining ties. One saved
  result closes the losing options.
- Cancel closes descendant waits. A stored cancellation rejects later input
  and clock advancement. It cannot undo previous Action I/O.
- Native snapshots and event replay retain pending requests, accepted input,
  and results. Runtime context must be supplied again. Effective bound input,
  validated Flow input, context, and metadata receive portability checks.
- Parallel branches at different dependency depths retain earlier join input
  when a later wait opens. Either completion order produces the same result
  and effect order after snapshot or event replay. Early buffered input and
  active input both have tests. Completed Actions do not run again.
- ETS compare-and-swap selects one stored revision. Equal save retries recover
  a lost reply. This does not prove that competing computation performed no I/O.

Equal clock advances do not append state. The driver retains input and
transition history in the graph. It has no supported compaction or byte limit.
A bounded input buffer does not bound that history. Do not infer bounded state
for a long-lived production execution from the 90-day deadline test.

## Runtime Limits And Host Responsibilities

Runic must own pending activation, suspension, completion, execution policy,
and recovery. The host must own the inbox, clock delivery, serialization,
retention, and an atomic save of its state and the native workflow. It must save
accepted input before acknowledgement and resolve uncertain save replies before
retrying work. The test Store does not provide this host transaction.

The wait operations run no Actions or hooks and do not implement a scheduler.
A host can stop a quiescent Runner Worker, save transitions, then resume it with fresh
runtime context and policy. The companion Jido package integrates this path
with durable AgentServer Turns. Ordinary managed Exec still rejects waits.
Saved history has no compaction or byte limit.

Opening a wait preserves earlier input at downstream joins. The wait records
its request without producing output or suppressing other branches. The test
host later resolves the saved request. This behavior does not provide native
Runner suspension. `Jido.Exec.Waits` provides request inspection, matching,
and resolution. It provides no inbox, Store API, or Signal transport.
Map and Iterate waiting Flow bodies remain unsupported.

A request needed by a wait in the same Turn must reach the host before the
wait. Deferred post-commit effects cannot issue that request from an unfinished
Turn. A production host must enforce this rule and test the complete recovery
contract before it can support wait execution.

## Tested Composition And Limits

The table below describes tests with the test driver. Normal Exec
rejects waiting Flows in these graph shapes.

| Form | Tested behavior and limits |
| --- | --- |
| Nested Flow | Each wait path includes every parent component. Native snapshots preserve completed Actions, partial results, pending waits, and effect order. Parent cancellation closes all descendants. |
| Invoke-selected Flow | A selected Flow can wait in the test driver. Its path includes the Invoke and all outer parents. Snapshot and native event replay preserve the selected graph without repeating the decision, expander, or completed child work. |
| Independent parallel waits | Each occurrence has its own activation ID. Either input order produces the same final value and canonical effect order. This does not race Actions. |
| Parallel waits at different depths | Opening a later wait preserves earlier join input. Snapshot and event replay preserve partial joins, completed Actions, and canonical effects with early or active input in either completion order. |
| Map with a Flow body | Unsupported. Map accepts an Action module. The DSL fails at compilation; map and Codec definitions fail target validation before any Action starts. Separate waiting Map items are unsupported. |
| Iterate with a Flow body | Unsupported. Iterate accepts an Action module. The same early rejection applies. Repeated waiting iterations are unsupported. |

A path identifies a component. The full wait ID identifies one activation and
its input occurrence in one execution. Use that ID for active input. Equal
component names in sibling nested Flows do not share input. Input from an old
execution cannot release a new occurrence. Early path input is limited to the
first static occurrence; it cannot address a future Invoke target.

The tests in `test/jido_exec/composed_waits_test.exs` cover these graph shapes
with the test driver. The companion Jido package owns AgentServer tests
for saved event acceptance, worker release, cancellation, and restart.
Nested Flow tests do not establish Map or Iterate wait support.

The wait-to-handoff test saves and restores the waiting graph, accepts input,
retries an equal save and duplicate input, and checks cancellation before the
Handoff. It returns a successor Instruction without running it. This covers
package result composition. Atomic Agent state and successor acceptance,
queue order, and caller-chain completion require AgentServer integration tests.

## Host Extension Points

`Jido.Exec.Waits` works on native Runic workflows. It does not provide a host
lifecycle. The host supplies `context(context, execution_id, clock)` before
Runic executes a wait node. The clock is a UTC millisecond value or a zero-arity
function read at each opening. The context function does not enable durable
validation. The host chooses that policy and supplies fresh runtime context
after restore. Runtime clock functions are not stored in the workflow.

`pending(workflow)` returns open requests with opaque execution-scoped IDs,
paths, resolved options, and opening times. Native node and Fact coordinates
remain internal. `next_deadline(workflow)` returns the earliest open timer
deadline, or nil. `matches?(request, event, payload)` checks event options.

After it stops the quiescent Worker, the host selects the accepted candidates
for one occurrence and calls `resolve(workflow, wait_id, candidates, now)`.
Each candidate contains `input: %{id: id, event: event, payload: payload}`,
`accepted_at`, and a unique `order` assigned by the host. Other input metadata
is ignored. Candidate times and orders are non-negative integers. Candidates
accepted after `now` are ignored. Earliest acceptance or deadline wins; timers
win exact-time ties, then receipt order and option order break other ties.

The host must save the returned graph before resuming Runic. Resolution
applies native result and completion events without calling Actions or hooks.
A pending resolution with no eligible candidate or timer leaves the graph
unchanged. Repeating a closed resolution is inert. An unknown occurrence or
malformed candidate returns a structured error.

The host owns duplicate IDs, input receipts, early-input policy, portability,
clock correction, retention limits, cancellation, and terminal receipts. It
must save accepted input before acknowledgement and save resolution before
running more work. Serialize writes with compare-and-swap and resolve uncertain
write outcomes through authoritative storage. Do not modify a running graph.
The companion Jido package owns these policies for durable AgentServer Turns.
Both the package test host and AgentServer use the same wait operations.
