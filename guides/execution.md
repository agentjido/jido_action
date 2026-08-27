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

A successful Flow returns `{:ok, result}`. Flow nodes discard Action extras.

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

## Runtime Options

All targets accept:

| Option | Default | Meaning |
| --- | --- | --- |
| `timeout` | `:infinity` | Complete-call limit for `run/4`. |
| `jido` | `nil` | Jido instance used for Action worker routing. |

Flow targets also accept:

| Option | Default | Meaning |
| --- | --- | --- |
| `async` | `false` | Runs independent ready work concurrently. |
| `max_concurrency` | scheduler count | Bounds tasks in each ready Runic wave. |

`start/4` accepts `jido`, `async`, and `max_concurrency`. It does not accept a
timeout because a paused execution has no complete-call clock.

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
value or integer ID. `wave/1` runs the set that was ready when the call began.
`continue/1` runs to a terminal state.

A failed runnable is an applied state transition. A step can return
`{:ok, failed_runnable, execution}`. Read the terminal error with `result/1`.

Always use the newest execution value. Each mutation consumes one revision.
Jido rejects concurrent reuse or later reuse of an old revision before it
starts Action work. An Execution is in-memory state, not a checkpoint or
storage format.

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
ownership, whole-call timeout, optional concurrency, and Jido instance
routing. It does not provide automatic retry, per-node deadlines, a public
cancel handle for running work, persistence, rewind, queues, recovery, or
distributed coordination.
