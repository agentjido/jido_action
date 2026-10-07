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

Flow modules use their `validate_params/1` and `validate_output/1` callbacks for
both direct execution and Subflow execution. This includes custom validation
and value transformations. Runtime `%Jido.Flow{}` values use their schemas.
Validator failures return structured Flow errors, including callbacks that
return plain error reasons or exceptions with no details map.

For an Action, Exec validates the target and input, runs `run/2` in the current
execution process, normalizes the callback result, and validates normal output.

For a Flow, Exec also validates the graph and targets, compiles the canonical
Flow to Runic, executes the graph, evaluates the explicit output, and validates
Flow output.

## Process Ownership

Each call starts one control Task under the selected `task_supervisor`.
That Task starts a private, linked Task Supervisor for the call. The private
supervisor owns all executable and runnable Tasks. These Tasks are temporary
and use `shutdown: :brutal_kill`, so cancellation also stops callbacks that
trap exits.

Each Action invocation uses a fresh Task for input validation, the callback,
output validation, and result normalization. Each root Flow uses a fresh Task
for materialization, validation, graph work, and final output validation.
This applies to synchronous calls, unlimited calls, asynchronous calls, and
continuations. An Action Task exits before the next root executable starts.
The caller waits for a result and does not execute these callbacks.

Tasks receive the caller's group leader. Exec does not copy, set, or reset
Logger metadata. Action changes to the process dictionary, mailbox, flags,
or Logger metadata do not transfer to another invocation. Runtime control
data stays outside public context.

| Work | Process use |
| --- | --- |
| Simple root Action | One control Task, one private supervisor, one Action Task. |
| Root Flow | One control Task, one private supervisor, one Flow Task, plus Action Tasks. |
| Step, Choice, Map item | One Task runs the Action and prepares its native result. No second wrapper Task. |
| Reduce, Iterate, Dispatch | Each Action invocation gets a fresh Task. Concurrent compound work also uses a runnable Task. |
| Subflow | Uses the root native graph and its existing Flow Task. |
| Continuation | Uses the existing control Task and private supervisor. Each next root executable gets a new Task. |
| Paused operation | Creates a new control Task, private supervisor, and Flow Task for that operation. Mutation also uses a revision helper. |

An unlimited or finite simple Action starts three framework processes. A Flow
with three serial Steps starts six: control, private supervisor, Flow, and
three Action Tasks. A Flow with two parallel Steps starts five. These counts
exclude the caller and the existing host supervisor. Synchronous and
asynchronous execution have the same process structure. Only the control Task
uses a slot in the selected host supervisor. `max_concurrency` limits admitted
Flow work across the root graph, including structural Subflows.

The control Task monitors the caller or async handle owner. Owner death stops
the call. Control Task death shuts down its private supervisor and its Tasks.
Flow Task or compound runnable failure also stops the call and its workers.
A normal Action error stops new dispatch; already admitted sibling Actions
can finish. A terminal result is returned after worker cleanup. There is no
worker registry, persistent owner process, or global ownership table.

One internal controller handles both synchronous and asynchronous calls. It
owns the deadline, owner monitor, and open telemetry spans. The Flow scheduler
collects standard Task replies and keeps the canonical result order. It does
not keep a second span tracker or worker ownership registry.

Workers also link to the controller. These links let cleanup find Actions
that trap exits if the private supervisor is killed before it can shut down
its children. A compound Task identifies itself before it starts an Action,
so its failure can stop the call even while the Flow scheduler is blocked.
Only root Tasks wait for a start check; nested Tasks need no permission message.

A paused `Execution` retains data and revision state, without a live control
Task, private supervisor, or captured call data. Each operation supplies new
call data and removes it before returning. The revision helper marks an interrupted
mutation indeterminate. Reuse of an old or indeterminate revision cannot
repeat Action work.

Raises, throws, and catchable exits return structured errors. A hard Action
Task exit returns `Jido.Action.Error.InternalError` with its original `reason`.
Flow adds the component path and execution phase. A killed Flow Task returns
`Jido.Flow.Error.InternalError`. Failure of a control Task returns
`Jido.Exec.Error.AsyncExecutionError`. No failure returns executable effects.

Malformed options and invalid routes use `Jido.Action.Error.InvalidInputError`
before any target descriptor is resolved. This includes non-keyword options
passed to `run_async/4`, which raises that error before a handle exists. Sync control startup failure returns an Action
`InternalError`; async control startup failure raises `AsyncExecutionError`.
Startup errors include the selected route, the reason, and `retry: false`.

Supervisor lookup and Task startup use synchronous OTP calls. A blocked host
registry or supervisor can delay the response beyond the timeout. The deadline
starts before host lookup, and the control Task checks it before dispatch.
Telemetry also remains synchronous. Blocked cleanup handlers can delay the
response. There is no startup or telemetry delivery helper.

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

`timeout: 0` returns `Jido.Exec.Error.TimeoutError` for every executable form.
It resolves no target and starts no executable work. Its public map type is
`:execution_timeout`. Once a nonzero execution budget starts, timeout errors
retain the current Action or Flow type. Continuation resolution retains the
previous target until the next target resolves.

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
| `task_supervisor` | `Jido.Exec.TaskSupervisor` | Local Task.Supervisor reference for the call control Task. |
| `max_continuations` | `256` | Maximum continuations in one complete call. |
| `max_concurrency` | `8` | Bounds ready Flow work if the chain runs a Flow. |
| `invocation` | none | Optional `Jido.Exec.Invocation` host configuration for Action receipts. |

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
complete call. It also rejects `invocation` through normal option validation.
An in-memory Execution is not a replay checkpoint.

## Replay Action Invocations

`run/4` and `run_async/4` accept one optional invocation host configuration:

```elixir
invocation = %{
  host: MyApp.InvocationHost,
  ref: host_ref,
  run_key: "order-123",
  compatibility: %{release: "2026-10"}
}

Jido.Exec.run(MyApp.OrderFlow, input, context, invocation: invocation)
```

The map has exactly these four fields. The `host` module implements
`Jido.Exec.Invocation`. The `ref` and
`compatibility` values are opaque host terms. The `run_key` is a nonempty
binary that identifies the logical run for the host. The configuration applies
to every Action in the complete call, including permitted continuations.
It covers root Actions, Action Instructions, Steps, Choice targets, Map items,
Reduce items, Iterate bodies, structural Subflows, and both Dispatch Actions.
Flow Instructions, Flow modules, and runtime Flow values use the same Action
edges inside their Flow work.

Exec calls two functions around the complete normalized Action boundary:

```elixir
@callback before_invoke(invocation, ref) ::
            :execute
            | {:replay, receipt}
            | {:interrupt, reason}
            | {:error, reason}

@callback after_invoke(receipt, ref) ::
            :ok
            | {:interrupt, reason}
            | {:error, reason}
```

`before_invoke/2` runs before Action input validation, `run/2`, and output
validation. `:execute` permits all three phases. `{:replay, receipt}` replaces
all three phases with the normalized outcome in that receipt. Exec does not
call `after_invoke/2` for replayed work.

For fresh work, Exec creates a receipt after the normalized Action result.
It calls `after_invoke/2` before that result can reach a dependent Flow
component or the root caller. The host returns `:ok` to accept the receipt.
An interrupt, an error return, an invalid callback return, or a callback
failure interrupts the complete Exec call. It does not become a collected
Action error.

The callbacks run in the existing Action Task. Concurrent Flow Actions can
call the host at the same time. The host must use the invocation key for each
lookup. It must not depend on callback completion order.

### Test Host Example

This small host sends callback data to a test process. It is an observation
fixture. It is not a storage adapter.

```elixir
defmodule MyApp.TestInvocationHost do
  @behaviour Jido.Exec.Invocation

  @impl true
  def before_invoke(invocation, test_pid) do
    send(test_pid, {:before_invoke, invocation})
    :execute
  end

  @impl true
  def after_invoke(receipt, test_pid) do
    send(test_pid, {:after_invoke, receipt})
    :ok
  end
end

opts = [
  invocation: %{
    host: MyApp.TestInvocationHost,
    ref: self(),
    run_key: "test-run-1",
    compatibility: :test_version
  }
]

{:ok, result} = Jido.Exec.run(MyApp.Actions.Work, %{}, %{}, opts)
```

### Descriptor And Receipt Data

Each callback receives version 1 data. An invocation descriptor has this
shape:

```elixir
%{
  version: 1,
  id: %{
    version: 1,
    run_key: "order-123",
    chain_index: 0,
    component_path: ["load", "items"],
    role: :map,
    selector: %{index: 2}
  },
  compatibility: compatibility,
  evidence: %{
    executable: %{kind: :flow, form: :module, module: MyApp.OrderFlow},
    flow_semantic_digest: semantic_digest,
    compilation_digest: compilation_digest
  },
  action: MyApp.Actions.LoadItem,
  params: resolved_params
}
```

The occurrence ID is independent of Task PIDs, telemetry IDs, completion
order, and native workflow revisions. The initial root segment has chain index
zero. Each accepted continuation increases it by one. `component_path` keeps
the full list of authored component names. It includes all structural Subflow
names.

The role and selector show the Action position:

| Role | Selector |
| --- | --- |
| `:root_action` | `nil` |
| `:step` | `nil` |
| `:choice` | `%{kind: :option, name: name}` or `%{kind: :fallback}` |
| `:map` | `%{index: zero_based_source_index}` |
| `:reduce` | `%{index: zero_based_source_index}` |
| `:iterate` | `%{index: zero_based_iteration_index}` |
| `:dispatch` | `%{phase: :decision}` or `%{phase: :expander}` |

`evidence.executable` describes the current root or continuation segment. Flow
segments also include the semantic and compilation digests from the prepared
Flow. These digests do not identify all Action code or helper code. Root Action
digests are `nil`. A Flow module uses `form: :module` and its module name. A
runtime Flow value uses `form: :value` and `module: nil`.

The descriptor has no raw context. `params` contains the resolved parameters
before Action input validation. If a Flow binding copies a context value into
parameters, Exec keeps that value unchanged in `params`.

A receipt keeps the historical descriptor and one normalized outcome:

```elixir
%{version: 1, invocation: invocation, outcome: outcome}
```

The outcome is one of:

```elixir
%{kind: :ok, output: output, effects: effects}
%{kind: :error, phase: :input | :execution | :output, error: exception}
%{kind: :continue, input: input, target: target}
```

Success output is a map or a valid `Jido.Action.Output`. Effects are a proper
list in canonical Action order. A continuation input is a map. The target is
the raw target returned by the Action.

On replay, Exec checks the protocol versions, exact occurrence ID, descriptor
shape, and normalized outcome shape. It does not require the historical and
current compatibility values, Action modules, parameters, or evidence to be
equal. The host compares those values and decides if it can return the receipt.

### Replay Model And Host Duties

Replay starts a new `run/4` or `run_async/4` call. Exec does not restore an
Execution. It materializes and runs orchestration again. At each Action edge,
the host can return a confirmed receipt. Exec then uses the saved Action
outcome. Work outside the Action boundary can run again. This work includes
Flow expressions, branching, parameter binding, Reduce accumulation, Iterate
state updates and completion checks, Flow validation, and materialization.
Flow output validation also runs again. An empty Flow has no Action edge, so it
does not call the invocation host.

The host and user must make this orchestration deterministic, or control its
changing inputs. Flow structure alone does not prove determinism. A changing
deadline, context value, validator, materializer, dispatch function, or state
function can change the replay path.

Structural Subflows use the full parent component path. Continuation targets
stay in the same Exec call and use the next chain index. If an Action calls
`Jido.Exec.run/4` or `run_async/4`, that nested call is a separate call. Its
work is opaque to the parent invocation. It gets no automatic child identity,
and this protocol cannot resume code inside an Action.

There is an uncertainty window after Action work and before the host accepts
the receipt. An external effect can finish before `after_invoke/2` returns
`:ok`. If the call stops in this window, Exec reports an interruption. It does
not state whether the effect occurred and it does not select a retry or
recovery action. The host must resolve this state. A host can also accept a
receipt before the caller receives the result. A new Exec call can then replay
that accepted receipt.

The host owns:

- compatibility decisions;
- durable intent and receipt storage when durability is required;
- receipt encoding and payload limits;
- recovery for missing, unresolved, or uncertain work; and
- delivery and deduplication of deferred effect requests.

A replayed success can return its deferred effect requests again. Exec keeps
their canonical order. The host must make durable delivery and deduplication
decisions.

Invocation and receipt maps use portable structural identity. Their payloads
keep normal Elixir value semantics. Exceptions, streams, PIDs, references,
functions, opaque Output values, and effect terms are not automatically
portable. Exec does not enumerate a stream or convert an exception map back
into an exception for storage.

This package supplies no journal, database, storage adapter, automatic retry,
backoff, compensation, lease, queue, exactly-once effect guarantee, Execution
snapshot, or durable engine.

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

All nested events use one `execution_id`. Each span also has a unique
`span_id`, its enclosing `parent_span_id` (or `nil` at the root), and a full
`node_path`. Start and terminal events share these values. Target spans cover
Steps, Choices, collection Actions, Iterate bodies, and Dispatch roles.
Error events add `error` and `error_type`. Collection and iteration events
can have high volume. Native Runic support nodes do not get artificial Jido
node events. A complete-call timeout closes each active Jido span once with
the timeout error.

Telemetry handlers run synchronously in the emitting process, as in V2.
Action and Flow events run in the Task that owns their lifecycle.
Flow target events run in the native runnable's execution process. After
timeout, cancellation, or hard worker failure, the controller emits error
events for the recorded open spans. The scheduler reports handled worker
failures to that controller. The controller stops the worker group on a
call failure and keeps the only span tracker in its existing receive loop.
Telemetry needs no process or ETS table.

Invocation replay keeps the normal lifecycle telemetry for the current Exec
call. A start or stop event can cover a replayed Action position. These events
do not prove that `before_invoke/2` returned `:execute`, or that Action input
validation, `run/2`, output validation, or `after_invoke/2` ran. Use the host's
own receipt data when that distinction matters.

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
termination. Each Action Task exits before the next root executable starts.
Explicit release closes each Action invocation; the monitor is the fallback when a kill prevents the `after` block. Make release idempotent. A
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
concurrency, explicit supervisor routing, and an optional Action receipt edge.
It does not provide automatic retry, per-node deadlines, durable cancellation,
persistence, rewind, queues, recovery, exactly-once effects, or distributed
coordination.
