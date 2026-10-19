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

Wait definitions, validation, and compilation are implemented. A supported wait
execution host is not implemented. Normal `Jido.Exec.run/4` and `start/6`
reject static waits before Action work. Dispatch checks a selected Flow before
any Action in that child graph runs. Its decision and expander have already run
to select the target. Do not use the test driver as an AgentServer runtime.

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
same result as its sole wait. Tests establish these rules in the proof driver.

## Recovery Proof

The [test driver](https://github.com/agentjido/jido_action/blob/feat/303-dispatch-handoff/test/support/wait_host.ex)
and its ETS Store are test support. They are excluded from the library build.
They provide a controlled clock and synchronous native snapshot transitions
for the package tests. They do not establish a second public Exec lifecycle.
Action work uses the same protected task boundary as immediate Exec.

The tests establish the following evidence:

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

Equal clock advances do not append state. The proof still retains input and
transition history in the graph. It has no supported compaction or byte limit.
A bounded input buffer does not bound that history. Do not infer bounded state
for a long-lived production execution from the 90-day deadline test.

## Required Runtime Work

Runic must own pending activation, suspension, completion, execution policy,
and recovery. The host must own the inbox, clock delivery, serialization,
retention, and an atomic save of its state and the native workflow. It must save
accepted input before acknowledgement and resolve uncertain save replies before
retrying work. The test Store does not provide this host transaction.

Native Runner suspension, managed retry and concurrency policy across waits,
AgentServer activation and restart, and bounded history remain unproved.
The mixed-depth join defect is fixed in the package wait node. Opening a wait
records its request and consumes the opening activation without producing
output. It must not skip the branch: a skip suppresses downstream join input
from other completed branches. The host later resolves the saved request.
This fix does not establish native Runner suspension. The
package adds no public wait driver, Store behavior, Signal transport, or second
scheduler. Map and Iterate waiting Flow bodies remain unsupported.

A request needed by a wait in the same Turn must reach the host before the
wait. Deferred post-commit effects cannot issue that request from an unfinished
Turn. A real host integration must establish this rule and the complete recovery
contract before wait execution becomes a supported public feature.

## Composition Evidence

| Form | Test proof scope and recovery evidence |
| --- | --- |
| Nested Flow | Each wait path includes every parent component. Native snapshots preserve completed Actions, partial results, pending waits, and effect order. Parent cancellation closes all descendants. |
| Dispatch-selected Flow | A selected Flow can wait. Its path includes the Dispatch and all outer parents. In this proof, snapshot and native event replay preserve the selected graph without repeating the decision, expander, or completed child work. |
| Independent parallel waits | Each occurrence has its own activation ID. Either input order produces the same final value and canonical effect order. This does not race Actions. |
| Parallel waits at different depths | Opening a later wait preserves earlier join input. Snapshot and event replay preserve partial joins, completed Actions, and canonical effects with early or active input in either completion order. |
| Map with a Flow body | Unsupported. Map accepts an Action module. The DSL fails at compilation; map and Codec definitions fail target validation before any Action starts. Separate waiting Map items have no established support. |
| Iterate with a Flow body | Unsupported. Iterate accepts an Action module. The same early rejection applies. Repeated waiting iterations have no established support. |

A path identifies a component. The full wait ID identifies one activation and
its input occurrence in one execution. Use that ID for active input. Equal
component names in sibling nested Flows do not share input. Input from an old
execution cannot release a new occurrence. Early path input is limited to the
first static occurrence; it cannot address a future Dispatch target.

The tests in `test/jido_exec/composed_waits_test.exs` use the test-only driver.
They establish evidence for these graph shapes. They do not establish AgentServer wait integration. Jido core
example `11_18` must supply end-to-end evidence for event acceptance, atomic
state save, worker release and activation, cancellation, and restart. Hosts
must not infer general Map or Iterate wait support from nested Flow tests.

The wait-to-handoff proof saves and restores the waiting graph, accepts input,
retries an equal save and duplicate input, and checks cancellation before the
Dispatch. It returns a successor Instruction without running it. This proves
package result composition. It does not prove atomic Agent state and successor
acceptance, queue order, or caller-chain completion in an AgentServer.
