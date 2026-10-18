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

{:ok, workflow} =
  Jido.Exec.Waits.start("turn-1", ApprovalFlow, %{order_id: "order-1"}, %{}, now: 100)

{:waiting, [request]} = Jido.Exec.Waits.status(workflow)
input = %{id: "approval-1", wait_id: request.id, event: "order.approved",
          payload: %{order_id: "order-1", approved: true}}
{:ok, completed} = Jido.Exec.Waits.accept(workflow, input, %{}, now: 200)
{:complete, {:ok, %{selected: "approved", value: %{approved: true}}}} =
  Jido.Exec.Waits.status(completed)
```

## Definitions And Results

A `timer "delay", after_ms: 100` returns `%{fired_at: absolute_deadline}`.
An `await "approval", event: "approved", match: %{id: input(:id)}` returns
the accepted payload map. A Selection with multiple options returns a map
with `selected`, `value`, `accepted_at`, and `input_id` (nil for a timer).
A one-option Selection is equivalent to its sole timer or event.

Map definitions use `kind: :timer`, `:await`, or `:selection`. A Selection
has `options`, a list of named timer and await definitions. They all lower
to one canonical `:wait` component. The DSL, data definitions, and Codec
share validation, dependencies, identity, and output. Match maps use exact
key/value comparisons against the payload. References create dependencies;
source order does not. Waits have no Action body and Selection does not race
Actions. Delays are non-negative integers with no 32-bit timer limit.

## Host Contract

`Jido.Exec.Waits` performs synchronous snapshot transitions with the native
Runic graph. Runic still owns readiness and Action execution. The returned
workflow has no active work while it waits. Keep or store the workflow, then
release the execution resources. Use `advance(workflow, context, now: ms)`
when a deadline is due. No running Action is needed for a 90-day wait.

The host supplies absolute wall-clock milliseconds and must not move time
backwards. Activation saves each deadline once. Restore does not recalculate
it. Supply runtime context again after restore. Context is absent from native
Runic snapshots. Params, context, input payloads, Action outputs, and effects
must be portable. Static waits fail at `Jido.Exec.run/4` and `start/6` before
work starts. Compile and validation remain inert.

Serialize transitions for each execution. Save the returned Runic snapshot
before acknowledging accepted input or completion. `Jido.Exec.WaitStore`
defines compare-and-swap and idempotent recovery from a lost save reply:

```elixir
store = Jido.Exec.WaitStore.Memory.new()
{:ok, 1} = Jido.Exec.WaitStore.Memory.save("turn-1", 0, workflow, store)
{:ok, 1} = Jido.Exec.WaitStore.Memory.save("turn-1", 0, workflow, store)
{:ok, 1, restored} = Jido.Exec.WaitStore.Memory.load("turn-1", store)
{:waiting, [_]} = Jido.Exec.Waits.status(restored)
Jido.Exec.WaitStore.Memory.close(store)
```

The ETS owner must outlive host workers. Memory survives those worker restarts,
and is lost at owner or VM exit. A persistent host supplies another adapter.
The adapter stores Runic's native snapshot, not a second checkpoint format.
Reload after an uncertain save reply. Never retry external Action work merely
because a save reply was lost. Prior I/O cannot be undone by this contract.

## Input, Selection, And Cancellation

Active input must use the full `wait_id`. That ID includes the native
activation and input occurrence. A foreign or closed wait ID is stale. Early
input can use `path: ["approval"]` for a statically declared component that
has not opened before. That form never addresses a later repeated occurrence.
Unknown dynamic paths are rejected. Input remains scoped to its execution.

Input IDs must be non-empty strings. Retrying identical input is inert, even
after completion. A different input with the same ID fails. Optional
`expires_at` is an absolute deadline; input at or after it expires. Buffered
input defaults to a limit of 128; set `max_buffered_inputs:` at start. Expired
and closed-target input does not occupy buffer capacity. Saved receipts retain
accepted time and order for deduplication. The host owns total history retention.

The earliest accepted matching input or timer deadline wins. Timers win an
exact-time tie. Accepted input order breaks input ties; declaration order
breaks remaining ties. Save one selected result and consumed input ID. Losing
options close together. They create no independent running timers to cancel.

`cancel/1` closes all descendant waits and is idempotent. Save cancellation
with the same compare-and-swap rule. An input/cancel race has one accepted
revision. Cancellation prevents later input and deadline advancement. It does
not reverse completed Actions or prior external I/O. Waiting, completion,
failure, and cancellation are distinct statuses. Effects are available only
from a successful final result, not from waiting or failed snapshots.

The execution host owns persistence, event transport, activation, and recovery.
This package has no Signal dependency or background delivery policy. A request
needed by a wait in the same Turn must use an explicit host interaction before
the wait. Post-commit effect requests cannot issue that request, because the
Turn has not committed while waiting. The host must test this integration;
AgentServer support is not established by these snapshot tests.
