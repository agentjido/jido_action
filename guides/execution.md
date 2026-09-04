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

For an Action, Exec validates the target and input, runs `run/2` in an owned
process, normalizes the callback result, and validates normal output.

For a Flow, Exec also validates the graph and targets, compiles the canonical
Flow to Runic, executes the graph, evaluates the explicit output, and validates
Flow output.

## Results And Errors

A successful direct Action or Action Instruction returns:

```elixir
{:ok, result}
{:ok, result, extras}
```

A Flow that finishes normally returns `{:ok, result}`. Flow nodes discard
Action extras. This includes explicit Steps, inline Steps, and the final Step,
in both run-to-completion and step-wise execution.

Extras are values for the caller. Jido Action and Exec do not interpret or
dispatch Actor Directives. If a higher-level runtime uses Action extras as
Directives, moving that Action into a Flow does not preserve their delivery.

A terminal Dispatch can continue to a final Action. That Action can return
extras to the caller of the complete Exec call. This does not collect extras
from earlier nodes. See
[Return Extras After A Flow](continuations.md#return-extras-after-a-flow).

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
`Jido.Action.Error.to_map/1` or `Jido.Flow.Error.to_map/1` for deterministic
external data. A runtime error can keep a `Splode.Stacktrace` in memory. The
stable map does not include it.

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

Call `handle_message/2` from `handle_info/2` or an equivalent OTP callback. It
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
`cancel/1` stops active work and closes its telemetry spans. It cannot undo
side effects that already completed.

Invalid handles and owner violations return
`Jido.Exec.Error.InvalidHandleError`. An unexpected failure of the managed
process returns `Jido.Exec.Error.AsyncExecutionError`.

## Runtime Options

All targets accept:

| Option | Default | Meaning |
| --- | --- | --- |
| `timeout` | `:infinity` | Complete-call limit for `run/4`. |
| `jido` | `nil` | Jido instance used for Action worker routing. |
| `max_continuations` | `256` | Maximum continuations in one complete call. |
| `max_concurrency` | `8` | Bounds ready Flow work if the chain runs a Flow. |

Use `max_concurrency: 1` for serial Flow scheduling. A value greater than `1`
runs independent ready work concurrently, up to the selected limit.

A failed runnable stops admission of pending work. Already admitted work can
finish, so concurrent work can still have side effects after another runnable
fails. Results from admitted work keep the original ready order. A Map with
`on_error: :collect_errors` returns failed items as data and continues admission.

An Action can return `{:continue, input, target}`. This result ends the current
executable and starts the target in the same complete call. The timeout and
continuation limit cover the full chain. See
[Continue to Another Executable](continuations.md).

`start/4` accepts `jido` and `max_concurrency`. It does not accept a timeout or
Dispatch because a paused execution cannot run a continuation as part of one
complete call.

## Step-wise Flow Execution

```elixir
{:ok, execution} = Jido.Exec.start(flow, input, context)

runnables = Jido.Exec.ready(execution)
status = Jido.Exec.status(execution)

{:ok, runnable, execution} = Jido.Exec.step(execution)
{:ok, runnables, execution} = Jido.Exec.wave(execution)
{:ok, execution} = Jido.Exec.continue(execution)
{:ok, result} = Jido.Exec.result(execution)
```

`ready/1` returns native `Runic.Workflow.Runnable` values. The ready set can
include authored work and native support work. Jido does not hide or drain
support runnables.

`workflow/1` returns the live prepared native Runic workflow. `compiled/1`
returns its component index and source map. These are read escape hatches for
debugging and native Runic inspection. A workflow changed outside Exec cannot
be applied back to an Execution through this API.

`step/1` runs the first ready runnable. `step/2` selects a ready runnable by
value or integer ID. `wave/1` runs work from the set that was ready when the call
began, and stops new dispatch on failure. Its returned list contains only the
runnables that were admitted.
`continue/1` runs to a terminal state.

A failed runnable is an applied state transition. A step can return
`{:ok, failed_runnable, execution}`. Read the terminal error with `result/1`.

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

## Scope

Exec provides one in-memory execution session. It provides validation, process
ownership, whole-call timeout, owner-bound async handles, optional
concurrency, and Jido instance routing. It does not provide automatic retry,
per-node deadlines, durable cancellation, persistence, rewind, queues,
recovery, or distributed coordination.
