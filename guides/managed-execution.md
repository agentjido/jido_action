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

See the `Runic.Runner` documentation for store adapters and other options.

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

Each execution ID can run once per Runner. Starting a second execution with an
ID that is still running returns an error.

## Read The Result

Wait for completion, then project the stored workflow to the public result:

```elixir
receive do
  {:done, "add-1"} -> :ok
end

{:ok, workflow} = Runic.Runner.get_workflow(MyApp.Runner, "add-1")
{:ok, %{value: 4}, [added: 1, added: 2]} = Jido.Exec.result(workflow)
```

`result/1` returns the same success or error contract as `run/4`. Do not read
the result before the execution completes.

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
| `max_concurrency` | `System.schedulers_online()` | Ready runnables that can run at once. |
| `dispatch_mode` | `:automatic` | `:manual` enables `Jido.Exec.step/2`. |
| `checkpoint_strategy` | `:every_cycle` | `:every_cycle`, `:on_complete`, `:manual`, or `{:every_n, n}`. |
| `on_complete` | none | `fn execution_id, workflow -> ... end`, called when no work remains. |
| `executor`, `executor_opts` | Runic Task executor | Replace how runnables are executed. |
| `scheduler`, `scheduler_opts` | Runic default | Replace how ready work is grouped. |
| `hooks`, `promise_opts` | none | Runic worker hooks and promise settings. |

The `max_concurrency` default differs from `run/4`, which defaults to `1`.
`task_supervisor` is not a managed option; the default executor uses the
Runner's own Task Supervisor. Unknown options return a configuration error.

See [Execution](execution.md#options) for how `timeout` and `max_attempts`
apply to runnables.

The native Runic executor owns Action tasks. Stop and cancellation wait for
native work to stop, including Actions that trap exits. A failed persistent
stop leaves the Worker and its active work alive so persistence can be retried.

An executor exit without a returned Runnable is an uncertain result. Runic
retains the unresolved activation and records the observed exit reason.
`result/1` returns an execution error with no executable effects. Use
`Runic.Runner.admission_status/2` to inspect stopped admission and active work.
Explicit recovery can repeat work that produced no accepted result.

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
{:ok, _pid} =
  Jido.Exec.start(MyApp.Runner, "add-3", MyApp.Flows.AddTwice, %{value: 10}, %{},
    dispatch_mode: :manual
  )

step_all = fn step_all, count ->
  case Jido.Exec.step(MyApp.Runner, "add-3") do
    {:ok, _workflow} -> step_all.(step_all, count + 1)
    {:error, :busy} -> step_all.(step_all, count)
    {:complete, workflow} -> {count, workflow}
  end
end

{_count, workflow} = step_all.(step_all, 0)

{:ok, %{value: 13}, [added: 1, added: 2]} = Jido.Exec.result(workflow)
```

`step/2` returns:

| Result | Meaning |
| --- | --- |
| `{:ok, workflow}` | One unit was dispatched. It may still be running. |
| `{:complete, workflow}` | No work is ready, or stopped admission has drained. Inspect the result. |
| `{:error, :busy}` | Previously admitted work is still running. Call again after it finishes. |
| `{:error, :automatic_dispatch}` | The execution was not started with `dispatch_mode: :manual`. |
| `{:error, :not_found}` | No execution has this ID. |

A scheduler unit is not always an authored Flow step. Flow input, output,
joins, and collection bookkeeping are units too. A failed execution also
returns `{:complete, workflow}`. Read its public result:

```elixir
Jido.Exec.result(workflow)
```

Call `Runic.Runner.continue/2` to switch a manual execution back to automatic
dispatch or reopen stopped admission after active work drains. Reopening an
uncertain execution can repeat work that has no accepted result.

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
completed work and continues with the remaining work. Completed Actions do not
run again. Jido keeps no separate checkpoint, and Flow JSON holds only the
definition.

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
