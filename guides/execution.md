# Execution Contract

`Jido.Exec` is the public execution and error boundary for Actions,
Instructions, and Flows.

## Run To Completion

```elixir
Jido.Exec.run(executable, input \\ %{}, context \\ %{}, opts \\ [])
```

The executable can be:

- an Action module;
- an Instruction;
- a Flow module; or
- a runtime `%Jido.Flow{}` value.

For an Action, Exec validates the target and input, runs `run/2` in the current
execution process, normalizes the callback result, and validates normal output.

For a Flow, Exec also validates the graph and targets, compiles the canonical
Flow to Runic, executes the graph, evaluates the explicit output, and validates
Flow output.

## Process Ownership

Actions do not start a worker or guard for each invocation. Validation, `run/2`,
output validation, and result normalization use the same execution process.

| Call | User code runs in | Deadline and cleanup |
| --- | --- | --- |
| Sync, `timeout: :infinity` | Caller | No timer or isolated worker. |
| Sync, finite timeout | One supervised execution worker | Caller enforces the complete-call deadline. Work may continue if the caller dies. |
| Async | One supervised execution worker | Live control task enforces the deadline, owner death, and cancellation. Work may continue if the control task dies. |
| Serial Flow | Current execution process | Uses the outer call's deadline and ownership. |
| Concurrent Flow wave | Bounded supervised workers | The scheduler owns its active-worker map. Work may continue if the scheduler dies. |
| Nested Flow | Current worker or an admitted concurrent worker | Keeps the outer deadline and concurrency limit. |
| Continuation | Same caller or execution worker | Keeps the original deadline. It does not start another Action worker. |
| Paused step, wave, or continue | Caller for serial work; wave workers for concurrent work | No timer. The revision helper marks interrupted mutations indeterminate. A completed pause operation leaves no workers. |

There are no guard processes for worker ownership. The revision helper still
prevents reuse of an execution revision. A managed controller holds
its execution worker PID and monitor, plus the PIDs of active concurrent work
for explicit cancellation. A concurrent scheduler uses its active-worker map.
Worker ownership requires no ETS table or global service. Normal and handled
error paths stop owned work and remove monitors and result messages. Reply
aliases discard late internal messages after the receive loop ends.

A living controller enforces the complete-call deadline and explicit
cancellation, including for callbacks that trap exits. The async controller
also monitors its handle owner and cancels work when that owner dies. This is
different from controller death: if a synchronous caller, async controller,
or direct scheduler dies abruptly, its workers may continue. Links and
`try/after` do not guarantee cleanup after arbitrary process death. A host
that needs stronger lifetime guarantees must own that policy.

A direct call shares the caller's mailbox, process dictionary, process flags,
Logger metadata, and group leader. Changes to these values can remain after
return. Serial callbacks in a managed call share these values within their
execution worker. Concurrent workers receive the scheduler's Logger metadata
and group leader. Do not assume that a fresh Action has a fresh process.

Raises, throws, and catchable exits still return structured errors. A direct
`Process.exit(self(), :kill)` kills the caller; Exec cannot catch it. A killed
managed worker returns an Action or Flow `InternalError` for the current
executable. It cannot identify an inner Action phase after a hard kill.
A killed concurrent worker returns a Flow runnable execution error. A supervisor
capacity or task-start failure at the managed boundary returns `InternalError`
with `reason`, `task_supervisor`, and `retry: false`. Routing validation before
managed worker startup uses `Jido.Action.Error.InvalidInputError`, before the
Action or Flow descriptor has been resolved. No error returns effects.

For a simple Action, framework process starts are 0 for a direct call, 1 for a
timed call, and 2 for an async call. Async adds one control task. A serial Flow
adds one revision helper per mutation, independent of its Action count. A
concurrent wave adds one worker per admitted runnable. Nested Flows can add
revision helpers. These counts exclude existing supervisors and processes
started by application code.

Supervisor lookup and task startup use normal synchronous OTP calls, as in V2.
A blocked host registry or supervisor can therefore delay the response beyond
the execution timeout. The deadline still starts before lookup and is checked
before the controller permits callbacks to run. It is not reset after startup.
The controller cannot handle cancellation while blocked in host startup code.
There is no startup helper, telemetry helper, or ETS table. Controllers and
schedulers keep worker monitors and open span records in their existing state.

## Results And Errors

A successful direct Action or Action Instruction returns:

```elixir
{:ok, result}
{:ok, result, requests}
```

An Action or Flow with deferred effect requests returns:

```elixir
{:ok, output, [request]}
```

The output has the same validation as an ordinary success. Effects must be a
proper list. Exec treats each request as an opaque value. It does not depend
on Jido core, validate Agent Directives, or execute them. A success with no
requests returns `{:ok, output}`, including an explicit empty batch.

A Flow collects effects from all successful executed components, including
components that its output does not reference. It keeps the final output
separate from the effect batch. These rules apply to explicit and inline
Steps, including the last Step, and to all supported authoring forms.

Effect order is deterministic:

1. Components use dependency depth, then component name, as in canonical Flow
   order. Worker completion order and selected step order do not change it.
2. A Subflow contributes its child effects once at its parent position. Child
   components use the same rule. Equal effect values are not removed.
3. Choice contributes only the selected option or fallback.
4. Map and Reduce use input item order. Iterate uses iteration order. Each
   Action's request list keeps its order. Empty work contributes no effects.
5. Dispatch contributes decision effects, then normal expander effects. A
   continuation keeps prior effects and appends the next executable's effects.
   The continuation itself requests no effects. Dispatch remains unavailable
   for step-wise execution and Subflows.

`start/4`, `step/1`, `step/2`, and `wave/1` do not publish executable partial
batches. Only a successful terminal `result/1` returns the complete batch.
Run-to-completion and supported step-wise execution have the same result.

A failed, timed-out, or cancelled execution returns no executable effect
batch, including effects from earlier successful steps or continuations.
Output validation must also succeed. A Map with `on_error: :collect_errors`
handles item errors as data: a successful Flow retains effects from successful
items only. Error extras never become success effects. Exec does not undo I/O
that Actions already performed. Native execution inspection can contain
intermediate data; it is not an effect dispatch API.

### Optional Effect Lists

Both a map and an Output value can have an optional effect list:

```elixir
{:ok, %{value: 42}}
{:ok, %{value: 42}, requests}
{:ok, Jido.Action.Output.stream(stream)}
{:ok, Jido.Action.Output.stream(stream), requests}
```

Run [Maps, Streams, And Optional Effects](action-effects.livemd) for complete
order approval and CSV export examples. Its integration tests execute the
same guide code through direct Actions, Flows, Instructions, async calls,
and step-wise execution.

`requests` must be a proper list. Omit it when there are no effects, or return
`[]`; Exec normalizes an empty list to the two-element success form. Exec does
not consume a stream to collect effects. Requests describe work after the
Action returns successfully; they do not imply that stream consumption has
finished. A later stream failure cannot cancel an already returned request.

The third success element is reserved for effects in direct Actions,
Instructions, and Flows. Non-list values, including `nil`, and improper lists
fail with `:invalid_effects`. Put other metadata in the output map or in
`Jido.Action.Output` metadata. Error results discard their third element and
return `{:error, error}`. Put diagnostic data in the error itself.

Existing `{:ok, output, requests}` Actions need no wrapper for Flow use.
Earlier versions silently dropped Flow node effects; this implementation
preserves them. See [Dynamic Flows](dynamic-flows.md#output-validation-and-effects).

Public failures are exception structs. Action boundary errors use:

- `Jido.Action.Error.InvalidInputError`;
- `Jido.Action.Error.ConfigurationError`;
- `Jido.Action.Error.ExecutionFailureError`;
- `Jido.Action.Error.TimeoutError`; and
- `Jido.Action.Error.InternalError`.

Flow boundary errors use:

- `Jido.Flow.Error.InvalidDefinitionError`;
- `Jido.Flow.Error.InvalidExecutionError`;
- `Jido.Flow.Error.ExecutionFailureError`;
- `Jido.Flow.Error.TimeoutError`; and
- `Jido.Flow.Error.InternalError`.

An Action failure inside a Flow keeps its Action error when possible. Use
`Jido.Action.Error.to_map/1`, `Jido.Flow.Error.to_map/1`, or
`Jido.Exec.Error.to_map/1` for the common public error-map shape. Detail values
remain unchanged and can contain runtime terms. Jido does not provide JSON or
other transport encoding for error structs. The host application must select
and convert detail values at its transport boundary.

A runtime error can keep a `Splode.Stacktrace` in memory. The public map omits
the exception's top-level stacktrace.

Exec does not retry work. Retryability in an error is information for a
higher-level caller.

## Run Asynchronously

```elixir
handle = Jido.Exec.run_async(executable, input, context, opts)

result = Jido.Exec.await(handle)
result = Jido.Exec.await(handle, 10_000)
{:done, result} = Jido.Exec.handle_message(handle, message)
:ok = Jido.Exec.cancel(handle)
```

`run_async/4` accepts each run-to-completion target that `run/4` accepts. It
returns a handle with `ref`, `pid`, `owner`, `monitor_ref`, and shared `state`
fields. Treat these fields as one handle. The process that calls `run_async/4`
owns the handle. Only that process can await, handle, or cancel it.

Start the call in the process that handles its completion. Use
`handle_message/2` in `handle_info/2` to keep a GenServer responsive. It
returns `{:done, result}` for the exact completion message and `:ignore` for an
unrelated message. A matching process exit returns the execution error inside
`{:done, {:error, error}}`. An invalid handle or owner returns the outer
`{:error, error}`.

`await/2`, `handle_message/2`, and `cancel/1` are alternative one-shot
terminal consumers. A completed message handler removes matching result and
monitor messages. Later duplicate result or stale monitor messages return
`:ignore`. A second wait returns `Jido.Exec.Error.InvalidHandleError`.

`await/1` waits for up to 5 seconds. `await/2` accepts a non-negative
millisecond value or `:infinity`. If this wait limit expires, Exec cancels the
active execution and returns `Jido.Exec.Error.AsyncTimeoutError`.

The `timeout:` option on `run_async/4` is different. It limits the complete
target execution and returns the normal Action or Flow timeout error.
`cancel/1` requires the complete handle. It stops active work and closes its
telemetry spans. It cannot undo side effects that already completed.

Invalid handles and owner violations return
`Jido.Exec.Error.InvalidHandleError`. An unexpected failure of the managed
process returns `Jido.Exec.Error.AsyncExecutionError`.

## Runtime Options

All targets accept:

| Option | Default | Meaning |
| --- | --- | --- |
| `timeout` | `:infinity` | Complete-call limit for `run/4`. |
| `task_supervisor` | `Jido.Exec.TaskSupervisor` | Local Task.Supervisor reference for execution workers, concurrent work, and async control. |
| `max_continuations` | `256` | Maximum continuations in one complete call. |
| `max_concurrency` | `8` | Bounds ready Flow work if the chain runs a Flow. |

Use `max_concurrency: 1` for serial Flow scheduling. A value greater than `1`
runs independent ready work concurrently, up to the selected limit.

A failed runnable stops admission of pending work. Already admitted work can
finish, so concurrent work can still have side effects after another runnable
fails. Results from admitted work keep the original ready order. A combined
Flow error lists failures in node-name order. A Map with
`on_error: :collect_errors` returns failed items as data and continues admission.

An Action can return `{:continue, input, target}`. This result ends the current
executable and starts the target in the same complete call. The timeout and
continuation limit cover the full chain. See
[Dynamic Flows](dynamic-flows.md).

`start/4` accepts `task_supervisor` and `max_concurrency`. It does not accept a timeout or
Dispatch because a paused execution cannot run a continuation as part of one
complete call.

## Read The Remaining Time

`Jido.Exec.remaining_time(context)` lets an Action or adapter read its budget:

- A non-negative integer is the remaining time in milliseconds.
- `0` means that the deadline has expired.
- `:infinity` means that the current work has no finite budget.
- `nil` means that context has no valid budget metadata.

For example, an Action can cap an external client's timeout:

```elixir
case Jido.Exec.remaining_time(context) do
  0 ->
    {:error,
     Jido.Action.Error.timeout_error("No time remains for the request", %{
       timeout: 0,
       retry: false
     })}

  remaining ->
    timeout = if is_integer(remaining), do: min(remaining, 5_000), else: 5_000
    MyApp.HTTP.get(url, timeout: timeout)
end
```

Here, `MyApp.HTTP` is an application adapter that returns a supported Action
result. Check the client's timeout semantics. Do not start a request with an
expired budget. This check cannot guarantee that time remains when the request
starts, or that an external write did not occur after a timeout.

Exec adds one reserved field to the context passed to Actions:

```elixir
%{tenant_id: "tenant-1", __jido_exec__: %{deadline: deadline}}
```

The deadline is an absolute monotonic time in milliseconds or `:infinity`.
Other context fields stay unchanged. Use the accessor instead of reading the
field directly. Exec rejects malformed reserved metadata before Action work.
The accessor itself returns `nil` for absent or malformed budget metadata.

The existing context paths pass this value through parallel Flow work,
Subflows, and continuations without restarting it. Pass the context explicitly
to nested `run/4` and `run_async/4` calls to use the earlier of the supplied and
local deadlines. A nested call with fresh context does not inherit a budget.
Existing controllers still own their
timeout enforcement and errors. Budget access does not add a timer, stop work,
or report cancellation. The outer timeout still applies if an adapter ignores
the budget.

There is no process-dictionary lookup. A Task can read the budget when given
the context. Passing context does not transfer cancellation ownership. Treat
this field as runtime-only: do not persist it or send it to another VM. It is
not an authorization credential or proof that an execution is still active.

Step-wise execution keeps the context supplied to `start/4`. Without budget
metadata it reads `:infinity`. A supplied finite deadline stays in that
context, so pause time reduces the remaining budget. This does not add a
step-wise timeout or cause automatic cancellation when that budget expires.

## Step-wise Flow Execution

```elixir
{:ok, execution} = Jido.Exec.start(flow, input, context)

work = Jido.Exec.ready(execution)
status = Jido.Exec.status(execution)

{:ok, completed, execution} = Jido.Exec.step(execution)
{:ok, completed, execution} = Jido.Exec.wave(execution)
{:ok, execution} = Jido.Exec.continue(execution)
{:ok, result} = Jido.Exec.result(execution)
```

`ready/1` returns `Jido.Exec.Work` descriptions with a token, component path,
kind, role, optional Map item index, and status. The ready set includes native
support work. Descriptions contain no application payloads or native graph.

`step/1` runs the first ready unit. Use `step(execution, work.token)` to select
another unit. Tokens are valid only in their execution revision. An invalid
or foreign token returns `InvalidExecutionError` before work starts and does
not consume a revision. Repeated `ready/1` calls return equal tokens.

`wave/1` runs work from the initial ready set and stops admission on failure.
Its results contain only admitted units, in ready order, with their input
tokens. After a mutation, use the new Execution and fresh tokens. Both can
move to another local process.

For advanced inspection, `native/1` returns the live workflow, compiled data,
and native ready values. Those values can retain application data and depend
on the Runic version. The API does not accept native workflow updates.
See [Debug Flows](debugging-flows.md) for examples.

A graph identity conflict fails the execution before downstream work can use
incorrect data. `result/1` returns `Jido.Flow.Error.ExecutionFailureError`
with `details.phase == :flow_identity` and `details.retry == false`. The
execution revision is consumed and the Flow emits one terminal error event.
The exception retains the original Runic stack trace.
Work already admitted in a concurrent wave can have completed its effects.

A failed work unit is an applied state transition. A step can return
`{:ok, %Jido.Exec.Work{status: :failed}, execution}`. Read the terminal error with `result/1`.

Always use the newest execution value. Each mutation consumes one revision.
Jido rejects concurrent reuse or later reuse of an old revision before it
starts Action work. An Execution is in-memory state, not a checkpoint or
storage format.

The step-wise API stays synchronous. `step/1` and `step/2` run one selected
runnable. `wave/1` and `continue/1` can run independent ready work
concurrently through `max_concurrency`. A paused Execution is not a target for
`run_async/4`.

## Telemetry Contract

Jido emits `:start`, `:stop`, and `:error` events for these prefixes:

```text
[:jido, :action]
[:jido, :flow]
[:jido, :flow, :node]
[:jido, :flow, :target]
[:jido, :flow, :map, :item]
[:jido, :flow, :reduce, :item]
[:jido, :flow, :iterate, :iteration]
```

All nested events use one `execution_id`. Error events add `error` and
`error_type`. Collection and iteration events can have high volume. Native
Runic support nodes do not get artificial Jido node events. A complete-call
timeout closes each active Jido span once with the timeout error.

Telemetry handlers run synchronously in the emitting process, as in V2.
Normal Action and Flow events run with their work. After timeout, cancellation,
or hard worker failure, the controller or scheduler stops the affected workers
and emits error events for their recorded open spans. It keeps those records
in its existing receive loop. Telemetry needs no process or ETS table.

A blocked start handler delays the Action body. A blocked terminal handler
delays completion. A finite deadline can kill a worker blocked in a handler,
but handlers invoked by the controller during cleanup can delay the response
beyond the deadline. There is no isolated delivery queue or 100 ms delivery
allowance. If a handler is interrupted or its controller dies, event delivery
can be incomplete. Jido does not repeat interrupted handler calls.

Start timestamps and terminal durations are captured when events are emitted.
Handlers share the emitting process's Logger metadata and group leader. They
can also change its process flags or dictionary. Keep handlers short and send
slow work to a process owned by the consumer. Untimed calls have no finite
complete-call deadline.

## External Resource Ownership

Stopping an Action worker does not prove that an external session, job, or
lease was released. A forced kill does not run the Action's `after` block.
Keep resource ownership in the adapter or host application, not in Flow
metadata or Action requirements.

A small pattern is one host-supervised process per session:

1. The owner monitors the Action worker before acquisition.
2. The owner acquires and records the session before returning it to the Action.
3. The Action uses the session and requests release in an `after` block.
4. On worker `DOWN`, the owner makes a bounded release request, reports its
   outcome to the host, and stops. Use a temporary child: restarting an empty
   owner cannot recover an external session.

The owner is supervised separately from Exec workers. It must survive their
termination. Normal return does not end a direct caller or a shared execution
worker. Explicit release closes each Action invocation; the monitor is the
fallback when a kill prevents the `after` block. Make release idempotent. A
session shared between Steps needs a different, host-owned lifetime.

For example, an application adapter can use this shape (these are application
modules, not new Jido APIs):

```elixir
def run(params, context) do
  with {:ok, owner, session} <-
         MyApp.SessionOwner.open(
           context.session_supervisor,
           context.session_service,
           context.resource_observer
         ) do
    try do
      MyApp.SessionClient.read(session, params)
    after
      MyApp.SessionOwner.close(owner)
    end
  end
end
```

The executable example is
[SessionOwner](https://github.com/agentjido/jido_action/blob/release/v3/test/support/fixtures/execution/session_owner.ex).
Its [system tests](https://github.com/agentjido/jido_action/blob/release/v3/test/system/resource_ownership_test.exs)
use a separate simulated service that does not release resources when clients
die. They verify the service's active-session state and release count, not
just worker termination. Run them locally with:

```text
mix test test/system/resource_ownership_test.exs --include system
```

### Limits Of This Pattern

Acquisition and release must have finite bounds. The example uses a
client-generated session ID and idempotent release. It can therefore attempt
release even when acquisition times out without a reply. A real service must
provide equivalent semantics; an unknown remote session ID or a late remote
allocation requires leases or reconciliation. The example is not a general
remote-resource manager.

Cleanup has its own time allowance because the Action's budget can already be
zero. Exec completion does not wait for this cleanup. A failed release is
reported separately and does not replace the Action result. It also does not
mean the resource was released: the tests explicitly retain the service
session when release fails or blocks.

The example does not recover from owner crashes, host shutdown, VM failure,
or network partitions. Use service-side expiry and host recovery where those
guarantees are required. A monitor cannot undo an external write or guarantee
remote cleanup.

## Scope

Exec provides one in-memory execution session. It provides validation, process
ownership, whole-call timeout, owner-bound async handles, optional
concurrency, and explicit supervisor routing. It does not provide automatic retry,
per-node deadlines, durable cancellation, persistence, rewind, queues,
recovery, or distributed coordination.
