# Execution

`Jido.Exec` is the one execution boundary for Actions and Flows. This guide
covers immediate execution with `run/4`, compilation with `compile/2`,
options, process behavior, and telemetry. For work that runs under a
supervised Runner, see [Managed Execution](managed-execution.md).

## How Exec Runs A Target

Every target takes the same path:

```text
Action module | Flow module | %Jido.Flow{} | %Jido.Instruction{}
  -> resolve to an Instruction (target, params, context)
  -> validate Flow input (Flow targets only)
  -> compile to a %Runic.Workflow{}
  -> run the workflow until no work remains
  -> {:ok, value} | {:ok, value, effects} | {:error, exception}
```

An Action compiles to a one-node workflow. A Flow compiles to a workflow
with one node per component plus the nodes that pass data between them.
Runic performs scheduling, timeouts, and retries.

## Run To Completion

```elixir
Jido.Exec.run(target, params \\ %{}, context \\ %{}, opts \\ [])
```

The examples in this guide use `MyApp.Actions.GreetUser` and
`MyApp.Flows.Welcome` from the Quick Tour in the README.

`params` and `context` can be maps, keyword lists, or `nil`. When the target
is an Instruction, call-site params and context replace equal keys in the
Instruction's own maps.

```elixir
{:ok, %{greeting: "Hello, Ada."}} =
  Jido.Exec.run(MyApp.Actions.GreetUser, %{name: "Ada"})

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
work that already started can finish. Exec uses stable admission order to
select an observed failure, so completion timing does not select the error.
Runic's events keep the actual completion order for audit.

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
failure or drained uncertain work also returns `{:complete, workflow}`;
use `Jido.Exec.result/1` to read its error.

Use `Runic.Runner.continue/2` to change the same worker back to automatic
dispatch. Use `dispatch_mode: :manual` with `Jido.Exec.resume/4` to keep
stepwise control after durable recovery. Use `Jido.Exec.result/1` on a
completed workflow to read its result.

Errors are exception structs from `Jido.Action.Error` or `Jido.Flow.Error`.
See [Errors](errors.md) for each error by phase.

Runic remains responsible for readiness, dispatch, active work, events,
persistence, and recovery. `Jido.Exec.step/2` only delegates dispatch and
returns Runic's current workflow state.

## Runtime Details

### Timeouts

`timeout` limits each attempt of each runnable. A runnable is one unit of
work in the compiled workflow: an Action call, or an internal Flow node such
as a Choice selector or a collection join. There is no limit on the complete
call. A Flow with three steps and `timeout: 50` can take longer than 50
milliseconds in total.

When an attempt exceeds the timeout, Exec kills it and returns
`Jido.Action.Error.TimeoutError`. `timeout: 0` fails every attempt.

### Retries

`max_attempts` above `1` retries a failed runnable only when
`Jido.Action.Error.retryable?/1` accepts the error. `backoff` selects the
delay:

| Backoff | Delay before attempt `n + 1` |
| --- | --- |
| `:none` | No delay. |
| `:linear` | `min(base_delay_ms * (n + 1), max_delay_ms)` |
| `:exponential` | `min(base_delay_ms * 2^n, max_delay_ms)` |
| `:jitter` | A random delay up to `min(base_delay_ms * 2^n, max_delay_ms)` |

Both delay options default to `0`, so set both when you want a delay.

> #### Retries repeat work {: .warning}
>
> Set `details.retry: true` only when another attempt is safe. Validation
> failures, timeouts, and process exits are not retried by default. Use
> `max_attempts` above `1` only when repeated Action work is safe.

```elixir
Jido.Exec.run(MyApp.Actions.FetchQuote, %{symbol: "ACME"}, %{},
  timeout: 2_000,
  max_attempts: 3,
  backoff: :exponential,
  base_delay_ms: 100,
  max_delay_ms: 1_000
)
```

### Concurrency

With the default `max_concurrency: 1`, ready work runs one runnable at a
time. With a larger value, independent Flow components and collection items
run concurrently, up to that limit.

```elixir
Jido.Exec.run(MyApp.Flows.BuildReport, input, %{}, max_concurrency: 4)
```

Concurrency does not change results. Flow results, collection results, and
effects keep their canonical order. Reduce and Iterate always run their
items in order. When one runnable fails, Exec starts no new work, but work
that already started can finish.

### Task Supervisor

`run/4` executes the call in a task under `Jido.Exec.TaskSupervisor`, which
the `:jido_action` application starts. Pass `task_supervisor:` to use your
own local Task Supervisor, for example to separate workloads:

```elixir
# In your application's supervision tree:
children = [
  {Task.Supervisor, name: MyApp.ExecSupervisor}
]

# Then, when you run work:
Jido.Exec.run(MyApp.Actions.GreetUser, %{name: "Ada"}, %{},
  task_supervisor: MyApp.ExecSupervisor
)
```

The value can be a PID, a registered name, or a `{:via, module, name}`
tuple. It must be running on the local node.

## Process Behavior

`run/4` blocks the calling process until the work finishes. It runs the work
in an unlinked task so that a crashing Action cannot crash the caller:

- The task keeps the caller's group leader, so `IO` output goes to the same
  place.
- A raise, throw, or exit in an Action becomes an error result.
- A killed execution task becomes `ExecutionFailureError` with
  `details.phase == :execution_task`.
- If the caller exits, Exec kills the task and all work that it started.

Close resources that an Action opens before it returns. Do not rely on
process exit for cleanup.

Stopping a managed execution, or the death of its worker, stops active Action
Tasks. A timeout or process exit becomes a failed Runnable. It is not retried.
Jido does not add another Task tree or cancellation model.

## Durable Boundaries

A durable execution has two separate records:

- the versioned Jido Flow definition, encoded with `Jido.Flow.Codec`; and
- the Runic execution state, stored through `Runic.Runner.Store`.

This split lets an application hydrate the same Flow definition and restore
the exact runtime frontier. A completed Action can have external effects that
cannot be rolled back. Use `Jido.Exec.effect_id/4` when the host needs a stable
deduplication identity. The host still owns effect delivery and transaction
policy.

## Telemetry

Exec emits `:telemetry` spans. `Jido.Exec.Telemetry.event_names/0` returns the
complete list:

| Event | When |
| --- | --- |
| `[:jido, :action, :start]` | An Action attempt starts. |
| `[:jido, :action, :stop]` | An Action attempt returns a success or an error. |
| `[:jido, :action, :exception]` | A raise, throw, or exit escapes the span. This is rare. |
| `[:jido, :flow, :start]` | `run/4` starts a Flow target. |
| `[:jido, :flow, :stop]` | That Flow run finishes. |
| `[:jido, :flow, :exception]` | A raise, throw, or exit escapes the Flow span. |

Measurements follow `:telemetry.span/3`: `monotonic_time` and `system_time` on
start, and `monotonic_time` and `duration` on stop.

Action metadata includes `action`, `action_name`, `node_name`, `runnable_id`,
`activation_id`, `attempt_id`, and `attempt`. Inside a Flow it also includes
`component`, `node_path`, `component_kind`, and, for Dispatch,
`dispatch_phase`. Flow metadata includes `flow` (the name) and, for Flow
modules, `target`.

Stop metadata adds `outcome`. A success adds `outcome: :ok` and
`effect_count`. An error adds `outcome: :error`, `error_type`, and
`retryable?`. Start and stop metadata do not include params, context,
results, or full errors.

Keep these limits in mind:

- Each retry attempt has its own Action span.
- When an attempt times out or is killed, only `:start` is emitted. Use the
  returned error, or the Flow `:stop` event, as the terminal signal.
- Managed execution emits Action spans but no Flow span. Runic emits runtime
  events under `[:runic, :runner, ...]`.

```elixir
:telemetry.attach_many(
  "my-app-jido-exec",
  Jido.Exec.Telemetry.event_names(),
  fn event, measurements, metadata, _config ->
    MyApp.Metrics.record(event, measurements, metadata)
  end,
  nil
)
```

## Scope

Exec runs Actions and Flows. It does not provide a database, a queue,
distributed coordination, or exactly-once effects. Use
[Managed Execution](managed-execution.md) for checkpoints and resume, and
your application or a higher-level runtime for the rest.
