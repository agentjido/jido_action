# Execution Contract

`Jido.Exec` is the public bridge from Jido definitions to Runic execution.
Every target uses the same path:

```text
Action or Flow
  -> Jido.Instruction
  -> Runic.Workflow
  -> Runic Runnable execution
```

An Action becomes a one-node workflow. A Flow becomes a workflow with real
Runic components and edges. Runic owns readiness, runnable identity,
scheduling, policy, event recording, checkpoints, persistence, and resume.

## Run To Completion

Use `run/4` for immediate in-memory execution:

```elixir
Jido.Exec.run(target, params \\ %{}, context \\ %{}, opts \\ [])
```

The target can be an Action module, Flow module, `Jido.Instruction`, or
canonical `%Jido.Flow{}`. Exec resolves the target, validates root Flow input,
compiles a Runic workflow, runs it until it stops, and projects the result.

```elixir
{:ok, result} = Jido.Exec.run(MyApp.Actions.Greet, %{name: "Ada"})

{:ok, result, effects} =
  Jido.Exec.run(MyApp.Flows.Notify, %{name: "Ada"}, %{request_id: "r-1"})
```

`run/4` uses Runic's immediate execution loop inside an unlinked temporary task
under `Jido.Exec.TaskSupervisor`. The task keeps the caller's group leader. It
does not create a Jido worker, execution struct, cursor, or checkpoint.

## Compile Without Running

Use `compile/2` when you need the native executable graph:

```elixir
{:ok, %Runic.Workflow{} = workflow} = Jido.Exec.compile(MyApp.Flows.Notify)
workflow = Jido.Exec.compile!(MyApp.Actions.Greet)
```

The compile options are:

| Option | Purpose |
| --- | --- |
| `source_map` | Add source locations to compiler errors. |
| `name` | Override the root Action node name. Action targets only. |
| `id` | Override the root Action node identity input. Action targets only. |

Flow modules supply their DSL source map automatically. Compiled workflows are
derived runtime values. Store the Flow definition as JSON and compile it after
hydration.

## Results And Errors

Successful execution returns one of these values:

```elixir
{:ok, value}
{:ok, value, effects}
```

The value is the validated Action output or Flow output. Effects are opaque
deferred requests. Exec does not dispatch them. Flow effect order follows
canonical dependency order. Collection effects follow item order.

Failed execution returns:

```elixir
{:error, exception}
```

Action validation, callback, and output failures keep their public Jido error
types. Flow coordination failures use `Jido.Flow.Error`. An Action failure is a
failed Runic Runnable. It is not a successful Fact that contains an error.

Actions can return:

```elixir
{:ok, value}
{:ok, value, effects}
{:error, reason}
{:error, reason, discarded_effects}
```

The effects list must be a proper list. Dynamic control belongs in Flow
components. Exec does not follow Action result continuations in a private loop.

## Immediate Runtime Options

`run/4` accepts these options:

| Option | Default | Rule |
| --- | --- | --- |
| `timeout` | `:infinity` | Per-attempt Runic timeout in milliseconds. |
| `max_attempts` | `1` | Total attempts, including the first. Only retryable errors retry. |
| `backoff` | `:none` | `:none`, `:linear`, `:exponential`, or `:jitter`. |
| `base_delay_ms` | `0` | Non-negative retry delay base. |
| `max_delay_ms` | `0` | Non-negative retry delay limit. |
| `max_concurrency` | `1` | Positive integer. Ready Runnable concurrency for immediate execution. |
| `task_supervisor` | `Jido.Exec.TaskSupervisor` | Local Task Supervisor for the execution task. |

Exec converts these options to `Runic.Workflow.SchedulerPolicy`. Runic performs
the timeout, retry, backoff, and scheduling work. Exec retries a failed attempt
only when `Jido.Action.Error.retryable?/1` accepts its error, so set
`details.retry: true` only when another attempt is safe. Timeouts and process
exits are not retried. Invalid option values return a
`Jido.Action.Error.ConfigurationError`.

The default failure action is `:halt`. A halting failure stops new dispatch;
work that already started can finish. The returned error is the first failure
that Runic recorded, for serial and concurrent execution.

## Managed And Durable Execution

Use `start/6` with a supervised `Runic.Runner`:

```elixir
Jido.Exec.start(
  runner,
  execution_id,
  target,
  params \\ %{},
  context \\ %{},
  opts \\ []
)
```

Example:

```elixir
children = [
  {Runic.Runner, name: MyApp.Runner}
]

{:ok, _supervisor} = Supervisor.start_link(children, strategy: :one_for_one)

{:ok, _worker} =
  Jido.Exec.start(
    MyApp.Runner,
    "order-42",
    MyApp.Flows.ProcessOrder,
    %{order_id: 42},
    %{request_id: "r-42"},
    checkpoint_strategy: :every_cycle
  )
```

Managed execution checks that Instruction parameters, context, and metadata
contain portable values. Context reaches Actions as runtime data and is not
stored in the Runic Store. Its default adapter runs Action Tasks under the
Runner's Task supervisor, including a partitioned supervisor.

Use the Runic API to checkpoint and stop. Use `Jido.Exec.resume/4` to resume,
and `Jido.Exec.result/1` to read the result:

```elixir
:ok = Runic.Runner.checkpoint(MyApp.Runner, "order-42")
:ok = Runic.Runner.stop(MyApp.Runner, "order-42", persist: true)

{:ok, _worker} =
  Jido.Exec.resume(MyApp.Runner, "order-42", %{request_id: "r-42"},
    checkpoint_strategy: :every_cycle
  )

{:ok, workflow} = Runic.Runner.get_workflow(MyApp.Runner, "order-42")
{:ok, value} = Jido.Exec.result(workflow)
```

Runic does not persist runtime context or runtime policy. Pass `resume/4` the
same context and managed options that you gave `start/6`. `result/1` returns
the same `{:ok, value}`, `{:ok, value, effects}`, or `{:error, exception}`
values as `run/4`.

The configured Runic Store is the source of truth for runtime progress. A
resume restores the Runnable frontier and continues with the next work. Jido
does not encode runtime progress into Instructions or Flow JSON.

Managed execution accepts Runic worker options such as `checkpoint_strategy`,
`on_complete`, `executor`, `scheduler`, and their option lists. It also accepts
the policy options listed above, except `max_concurrency` is a worker option.

## Stepwise Execution

Automatic dispatch is the default. Set `dispatch_mode: :manual` when a caller
must inspect a managed Flow between Runic scheduler units:

```elixir
{:ok, _worker} =
  Jido.Exec.start(
    MyApp.Runner,
    "order-42",
    MyApp.Flows.ProcessOrder,
    %{order_id: 42},
    %{},
    dispatch_mode: :manual,
    checkpoint_strategy: :every_cycle
  )

case Jido.Exec.step(MyApp.Runner, "order-42") do
  {:ok, %Runic.Workflow{} = workflow} ->
    # One scheduler unit was dispatched. Inspect the current Runic state.
    workflow

  {:complete, %Runic.Workflow{} = workflow} ->
    # No ready work remains. Inspect results or failure events.
    workflow

  {:error, :busy} ->
    # The prior unit is still active. Try again after it completes.
    :busy
end
```

With the default scheduler, one call dispatches one Runnable. A batching
scheduler can define a larger scheduler unit. A Runic unit is not always one
authored Flow Step. Flow output, control, join, and collection components are
also executable Runic units.

`step/2` returns the current `%Runic.Workflow{}` after dispatch. The dispatched
unit can still be active. Call it again after the unit finishes. A terminal
failure also returns `{:complete, workflow}` because no ready work remains;
inspect `workflow.runnable_events` for `Runic.Workflow.RunnableFailed`.

Use `Runic.Runner.continue/2` to change the same worker back to automatic
dispatch. Use `dispatch_mode: :manual` with `Jido.Exec.resume/4` to keep
stepwise control after durable recovery. Use `Jido.Exec.result/1` on a
completed workflow to read its result.

Runic remains responsible for readiness, dispatch, active work, events,
persistence, and recovery. `Jido.Exec.step/2` only delegates the dispatch and
returns Runic's current workflow state.

## Durable Boundaries

A durable execution has two separate records:

- the versioned Jido Flow definition, encoded with `Jido.Flow.Codec`;
- the Runic execution state, stored through `Runic.Runner.Store`.

This split lets an application hydrate the same Flow definition and restore the
exact runtime frontier. The package tests cover a ten-Action Flow that stops
after Action 5 and resumes at Action 6. They also cover recovery for Map,
Iterate, nested Flow, and Dispatch work.

A completed Action can have external effects that cannot be rolled back. Use a
stable effect identity from `Jido.Exec.effect_id/4` when a host needs deduplication.
The host still owns effect delivery and its transaction policy.

## Process And Policy Ownership

Runic owns the Worker, Scheduler, Executor, Task supervisor, and Store. Jido
provides the Action adapter and the default managed Executor. A host can replace
Runic's public scheduler, executor, or store components.

Stopping a managed execution, or the death of its worker, stops active Action
Tasks. A timeout or process exit becomes a failed Runnable. It is not retried.
Jido does not add another Task tree or cancellation model.

## Telemetry

Jido emits semantic spans for Action attempts and immediate Flow invocations:

- `[:jido, :action, :start | :stop | :exception]`
- `[:jido, :flow, :start | :stop | :exception]`

A normal returned error emits `:stop` with `outcome: :error`. The `:exception`
event is for a raise, throw, or exit that escapes the span. Metadata includes
static Action or Flow identity, authored Flow location, and Runic activation
and attempt identities. Start and normal stop metadata do not include
parameters, context, results, effects, complete errors, or stacktraces. A
standard `:telemetry.span/3` exception event includes its reason and
stacktrace.

Runic emits managed runtime telemetry under `[:runic, :runner, ...]`. Use those
events for workflow lifecycle, runnable dispatch, persistence, promises, and
rehydration. Jido does not copy those events under a second prefix. Managed
Action spans can be correlated with Runic runnable events by `runnable_id`.

A durable execution does not keep one Jido Flow span open across process stop
and resume. Runic workflow events describe each managed runtime lifecycle.

Runic can terminate an Action process after a timeout or cancellation. Such an
Action attempt can emit `:start` without a terminal Jido event. For managed
execution, use the Runic runnable failure event as the terminal runtime signal.
For immediate execution, use the returned Exec error and the outer Flow span,
when the target is a Flow.

## Scope

`Jido.Exec` provides Action and Flow execution. It does not provide a database,
queue, lease service, distributed coordinator, or exactly-once external effect
guarantee. Use Runic Store and Runner adapters, plus application services, for
those responsibilities.
