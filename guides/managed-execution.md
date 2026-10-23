# Managed Execution

`Jido.Exec.run/4` runs work to completion in the calling process's lifetime.
Managed execution runs the same Action or Flow under a supervised
`Runic.Runner` instead. Use it when work must:

- continue after the process that started it exits;
- checkpoint progress and resume after a restart;
- be stepped one unit at a time for inspection or tooling; or
- be observed by other processes while it runs.

Jido compiles the target and starts it. Runic owns the worker, the store,
checkpoints, and recovery. Use `Runic.Runner` functions for lifecycle work.

## Add A Runner

A `Runic.Runner` is a supervisor. It owns a store (ETS by default), a worker
registry, a Task Supervisor, and the workers for each execution. Add one to
your application's supervision tree:

```elixir
children = [
  {Runic.Runner, name: MyApp.Runner}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

The default ETS Store keeps data only while its owning Store process lives.
It can support worker stop and resume within that lifetime. It does not
survive a Store, Runner, or VM restart. For recovery across those restarts,
configure a Runic Store adapter that persists data outside those processes.
See `Runic.Runner.Store` for the adapter contract.

## Start An Execution

The examples use this Action and Flow:

```elixir
defmodule MyApp.Actions.Add do
  use Jido.Action,
    name: "add",
    schema: Zoi.object(%{value: Zoi.integer(), amount: Zoi.integer()}),
    output_schema: Zoi.object(%{value: Zoi.integer()})

  @impl true
  def run(%{value: value, amount: amount}, _context) do
    {:ok, %{value: value + amount}, [{:added, amount}]}
  end
end

defmodule MyApp.Flows.AddTwice do
  use Jido.Flow,
    name: "add_twice",
    schema: Zoi.object(%{value: Zoi.integer()})

  flow do
    step "first",
      action: MyApp.Actions.Add,
      params: %{value: input(:value), amount: 1}

    step "second",
      action: MyApp.Actions.Add,
      params: %{value: result("first", :value), amount: 2}

    output result("second")
  end
end
```

Call `Jido.Exec.start/6` with the Runner, a stable execution ID, the target,
params, context, and options:

```elixir
parent = self()

{:ok, _pid} =
  Jido.Exec.start(
    MyApp.Runner,
    "add-1",
    MyApp.Flows.AddTwice,
    %{value: 1},
    %{request_id: "req-1"},
    on_complete: fn execution_id, _workflow -> send(parent, {:done, execution_id}) end
  )
```

`start/6` validates Flow input, checks that params and context are portable,
compiles the target, starts a worker, and requests dispatch. Work can start
before `start/6` returns. A later Action failure does not change the successful
start return value.

Use a unique ID for each logical execution. Starting another worker with an
ID that is still registered returns an error. Use `resume/4` to restore stored
work instead of starting it again.

## Read The Result

Wait for completion, then read the public result:

```elixir
receive do
  {:done, "add-1"} -> :ok
after
  5_000 -> raise "the managed execution did not finish"
end

{:ok, %{value: 4}, [added: 1, added: 2]} = Jido.Exec.result(MyApp.Runner, "add-1")
```

`result(runner, execution_id)` returns the same success, handoff, or error contract as
`run/4`. It uses the Runic observation for the input admitted by `start/6`.
Active or ready work returns an error with `details.reason: :execution_active`.
Later input occurrences do not replace this result.

A terminal Dispatch returns `{:handoff, successor_instruction, effects}` through
the same result API, including after resume. Every host must handle this result.
See [Dynamic Flows](dynamic-flows.md#terminal-handoff-to-a-new-turn) for the host rules.

Computation and Store acknowledgement are separate. Read
`Runic.Runner.persistence_status/2` before treating a result as stored.

## Options

`start/6` accepts the retry and timeout options of `run/4` and Runic worker
options:

| Option | Default | Meaning |
| --- | --- | --- |
| `timeout` | `:infinity` | Limit for each runnable attempt, in milliseconds. |
| `max_attempts` | `1` | Total attempts for a failed runnable. |
| `backoff` | `:none` | `:none`, `:linear`, `:exponential`, or `:jitter`. |
| `base_delay_ms` | `0` | Base retry delay. |
| `max_delay_ms` | `0` | Maximum retry delay. |
| `max_concurrency` | Application configuration, or `min(System.schedulers_online(), 10)` | Ready runnables that can run at once. |
| `dispatch_mode` | `:automatic` | `:manual` enables `Jido.Exec.step/2`. |
| `checkpoint_strategy` | `:every_cycle` | `:every_cycle`, `:on_complete`, `:manual`, or `{:every_n, n}`. |
| `on_complete` | none | `fn execution_id, workflow -> ... end`, called when no work remains. |
| `executor`, `executor_opts` | Runic Task executor | Replace how runnables are executed. |
| `scheduler`, `scheduler_opts` | Runic default | Replace how ready work is grouped. |
| `hooks`, `promise_opts` | none | Runic worker hooks and promise settings. |

Set the package value with `config :jido_action, max_concurrency: value`. The
`max_concurrency` default is the same for managed execution and `run/4`. An
explicit execution option overrides the configured value.
`task_supervisor` is not a managed option; the default executor uses the
Runner's own Task Supervisor. A custom executor defines how its work runs.
Unknown options return a configuration error.

See [Execution](execution.md#immediate-runtime-options) for how `timeout` and `max_attempts`
apply to runnables.

## Keep Data Portable

A managed execution can be stored and resumed in another process, so its data
must not depend on the current process. `start/6` rejects params and context
that contain a PID, port, reference, or function anywhere inside them:

```elixir
{:error, %Jido.Action.Error.ExecutionFailureError{details: details}} =
  Jido.Exec.start(MyApp.Runner, "add-2", MyApp.Flows.AddTwice, %{value: 1}, %{reply_to: self()})

%{reason: :non_portable_durable_value, path: [:context, :reply_to]} = details
```

The same check applies to each Action's output and effects during a managed
execution. Pass process identities through your own registry or a stable name
instead.

## Step Through An Execution

Start with `dispatch_mode: :manual` to control dispatch yourself. Each
`Jido.Exec.step/2` call dispatches one scheduler unit. With the default
scheduler, that is one runnable.

```elixir
parent = self()

{:ok, _pid} =
  Jido.Exec.start(MyApp.Runner, "add-3", MyApp.Flows.AddTwice, %{value: 10}, %{},
    dispatch_mode: :manual,
    hooks: [
      on_complete: fn _runnable, _duration, _state -> send(parent, {:unit_done, "add-3"}) end,
      on_failed: fn _runnable, _reason, _state -> send(parent, {:unit_done, "add-3"}) end
    ]
  )

step_all = fn step_all, count ->
  case Jido.Exec.step(MyApp.Runner, "add-3") do
    {:ok, _workflow} ->
      receive do
        {:unit_done, "add-3"} -> step_all.(step_all, count + 1)
      after
        5_000 -> raise "the scheduler unit did not finish"
      end

    {:complete, workflow} ->
      {count, workflow}

    {:error, reason} ->
      raise "cannot step execution: #{inspect(reason)}"
  end
end

{_count, _workflow} = step_all.(step_all, 0)

{:ok, %{value: 13}, [added: 1, added: 2]} = Jido.Exec.result(MyApp.Runner, "add-3")
```

The example waits for each scheduler unit through Runic hooks. It does not
poll `step/2` while a unit is active. Keep hooks short; they run in the Worker.

`step/2` returns:

| Result | Meaning |
| --- | --- |
| `{:ok, workflow}` | One unit was dispatched. It may still be running. |
| `{:complete, workflow}` | No work is ready, or admission stopped after failure or uncertain work. |
| `{:error, :busy}` | The previous unit is still running. Call again after it finishes. |
| `{:error, :automatic_dispatch}` | The execution was not started with `dispatch_mode: :manual`. |
| `{:error, :not_found}` | No execution has this ID. |

A scheduler unit is not always an authored Flow step. Flow input, output,
joins, and collection bookkeeping are units too. A failed execution also
returns `{:complete, workflow}`. A stopped scope can retain ready work. Read
`Jido.Exec.result(runner, execution_id)` for the terminal result. Uncertain
executor work returns an error with the original reason and
`details.retry: false`; it does not become
a fabricated node failure or automatically restart. Failure selection follows
causal depth, component name, and collection item order.

Call `Runic.Runner.continue/2` to switch a manual execution back to automatic
dispatch.

## Checkpoint, Stop, And Resume

Use the Runner for durable lifecycle control:

```elixir
:ok = Runic.Runner.checkpoint(MyApp.Runner, "add-1")
:ok = Runic.Runner.stop(MyApp.Runner, "add-1", persist: true)
{:ok, _pid} =
  Jido.Exec.resume(MyApp.Runner, "add-1", %{request_id: "req-1"},
    checkpoint_strategy: :every_cycle
  )
```

The Runic store is the source of truth for progress. A resume restores the
acknowledged stored completed work and continues with the remaining work.
Work completed after the last acknowledged checkpoint can run again. Jido
keeps no separate checkpoint, and Flow JSON holds only the definition.

Managed execution continues after its caller exits. Runic owns its active
tasks. With the default executor, a successful `Runic.Runner.stop/3` or
`cancel/2` waits for those tasks to exit. If a persistent stop cannot save the
workflow, it returns an error and keeps the same Worker and tasks running.

Runic observations are process-local and are not restored from the Store.
After resume, `result(runner, execution_id)` checks for active and ready work,
then projects the restored snapshot. This path includes historical failure
and uncertainty events. `result(workflow)` remains available for a completed
snapshot obtained directly from Runic.

> #### Supply context and policy again {: .warning}
>
> Runic does not store runtime context or policy. Resume with
> `Jido.Exec.resume/4` and pass the same context and managed options that were
> given to `start/6`.

## Effects And Repeated Work

A completed Action can have external effects that cannot be undone. A crash
between the effect and the checkpoint can repeat that Action after a resume.
Make effects idempotent, or return them as effect requests and perform them
after the execution completes.

`Jido.Exec.effect_id/4` derives a stable identity for one effect from the
execution ID, the Runic activation and output IDs, and the effect index. Use it
when your effect delivery needs a deduplication key.

## Telemetry

Managed execution emits Jido `[:jido, :action, ...]` spans for each Action
attempt. It does not emit a `[:jido, :flow, ...]` span. Runic emits worker,
dispatch, persistence, and recovery events under `[:runic, :runner, ...]`.
Correlate the two by `runnable_id`. See [Execution](execution.md#telemetry).

## Retry Recovery Limits

These limits are tested with Runic `0.1.0-alpha.12`. This version keeps the retry
loop inside one task.
A failed attempt can enter backoff before its attempt events reach the Worker.
A checkpoint at that point cannot save a retry budget or an absolute retry
deadline. Restore can repeat that activation from attempt zero and grant it a
new budget. Delayed backoff retains the task and its concurrency slot. The
native API supplies no controlled retry clock or observable retry deadline.

Use native `Runic.Runner.admission_status/2` and `persistence_status/2` to
inspect current admission and Store acknowledgement. These are separate
observations. They do not provide a saved retry count or deadline.
Quiescence does not mean success; read `Jido.Exec.result/2` for the outcome.
Read these native status APIs directly. A downstream project can select
another Runic version, so it must verify these limits against its own
dependency lock.

Accepted completed work and terminal failures survive save/restore. A terminal
retry-limit failure and a non-retryable failure are not new pending attempts.
An unresolved task is a different boundary: it can run again after recovery.
Cancellation stops a native task during backoff, but cancellation does not
undo previous I/O. Checkpoint acknowledgement and a completed result remain
separate facts.

The recovery tests check attempt counts before and after restore. They also
check that backoff retains a task and that cancellation stops it. The native
API has no controlled retry clock for testing a saved absolute retry deadline.

Hosts must not advertise durable retry budgets or resource-free delayed retry
with this dependency. Durable retry support requires native Runic attempt
acceptance, saved deadlines, and a controlled retry clock. Jido uses Runic
retry policy and `max_attempts`; it provides no separate retry counter,
backoff scheduler, checkpoint format, or retry API.
