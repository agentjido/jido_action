# Runtime Configuration

Actions and Flows define work and data. Runtime policy belongs to
`Jido.Exec.run/4` or `Jido.Exec.start/4`.

## Common Run Options

All resolved targets accept these options in `run/4`:

| Option | Default | Rule |
| --- | --- | --- |
| `timeout` | `:infinity` | `:infinity` or a non-negative millisecond integer. |
| `task_supervisor` | `Jido.Exec.TaskSupervisor` | A local Task.Supervisor PID, registered name, or via reference. |
| `max_continuations` | `256` | An integer from `0` through `10_000`. |
| `max_concurrency` | `8` | A positive integer used if the chain runs a Flow. |

A finite timeout covers the complete call. It terminates the execution process
and active child work. It does not retry the target.

`max_continuations` covers the complete Action and Flow chain. A value of `0`
rejects the first continuation. The fixed upper bound prevents a caller from
removing this safety limit. The complete-call timeout is a second guard.

`start/4` accepts `task_supervisor` and `max_concurrency`, but not `timeout` or
`max_continuations`. A paused step-wise execution does not have one
complete-call clock and cannot run a continuation. Use `continue/1` to run it
to completion.

## Flow Scheduling

`max_concurrency: 1` runs ready work serially. A value greater than `1`
dispatches independent work concurrently and bounds the tasks in that wave.
Map items are native Runic runnables and use the same rule. There is no second
Jido concurrency budget.

Reduce and Iterate Action work stays serial.

```elixir
Jido.Exec.run(
  MyApp.Flows.BuildReport,
  input,
  context,
  timeout: 10_000,
  max_concurrency: 4
)
```

Unknown options are errors. An Action does not use `max_concurrency` itself,
but its continuation can select a Flow. An Instruction follows the option
rules of its target. The removed Flow `async:` option is an unknown option.

## Task Supervisor References

Pass the supervisor reference directly. The host owns its name, capacity, and
shutdown policy. Exec does not derive a name or create routing atoms.

```elixir
children = [
  {Task.Supervisor, name: MyApp.ReportTasks, max_children: 1_000}
]

# Add these children to the host application supervision tree.
Supervisor.start_link(children, strategy: :one_for_one)

Jido.Exec.run(MyApp.Flows.BuildReport, input, context,
  task_supervisor: MyApp.ReportTasks,
  max_concurrency: 4
)
```

An unnamed supervisor is also valid:

```elixir
{:ok, supervisor} = Task.Supervisor.start_link()
Jido.Exec.run(MyApp.Flows.BuildReport, input, context, task_supervisor: supervisor)
```

A Registry route selects a supervisor registered with that key:

```elixir
children = [
  {Registry, keys: :unique, name: MyApp.TaskRegistry},
  {Task.Supervisor, name: {:via, Registry, {MyApp.TaskRegistry, "reports"}}}
]

Supervisor.start_link(children, strategy: :one_for_one)
route = {:via, Registry, {MyApp.TaskRegistry, "reports"}}
Jido.Exec.run(MyApp.Flows.BuildReport, input, context, task_supervisor: route)
```

PartitionSupervisor can distribute task starts across local supervisors. Build
one route in the calling process and pass it to Exec:

```elixir
children = [
  {PartitionSupervisor, child_spec: Task.Supervisor, name: MyApp.ReportPartitions}
]

Supervisor.start_link(children, strategy: :one_for_one)
route = {:via, PartitionSupervisor, {MyApp.ReportPartitions, self()}}
handle = Jido.Exec.run_async(MyApp.Flows.BuildReport, input, context,
  task_supervisor: route)
```

Exec keeps this exact route, including its partition key, through async,
finite-timeout, step-wise, nested, collection, and continuation work. It does
not select a new partition from an internal worker PID. See the official
[Task.Supervisor routing contract](https://elixir.hexdocs.pm/1.18.4/Task.Supervisor.html#module-scalability-and-partitioning).

### Lifetime And Failures

The reference must select a local Task.Supervisor. Remote PIDs, remote name
tuples, and `:global` references are not supported. A via resolver must return
a local PID or report that no process is registered. Omit `task_supervisor`
to use the package default. An explicit `nil` is invalid. Duplicate
`task_supervisor` options and the removed `jido` option are errors.

Exec checks the selected route before work. Each task start resolves names
and via references again. If the supervisor stops, active tasks stop and the
call returns a structured error. Tasks are temporary and are not restarted.
If the same name is registered again, later work can use the replacement.
This includes a later step of a paused Flow or a later task in the same call.
Use a PID when all work must use one specific supervisor process; a dead PID
never selects its replacement. Neither route provides rollback or retry.

There is no fallback to the package supervisor. Absence and invalid routes
produce Action or Flow validation errors. Capacity refusal and task-start
races produce execution errors with `task_supervisor` and `reason` details.
The route in those details is the supplied reference. Local lookup exceptions,
throws, and exits are contained at the same boundary.

`run_async/4` must start its control task before it can return a handle. Invalid
routing raises `Jido.Action.Error.InvalidInputError`. Failure to start that
task raises `Jido.Exec.Error.AsyncExecutionError`. After the handle exists,
use its result or completion message to receive failures. The control task
uses one supervisor slot in addition to active Action workers. For example,
`max_children: 1` cannot run an async Action under that same supervisor.

The selected supervisor owns isolated Action workers, including Flow target
Actions, and the async control task. The finite-timeout coordinator, caller
watchers, telemetry processes, and Runic stream helpers keep their existing
ownership rules. They are not all direct children of the Task.Supervisor.
Caller death and cancellation still stop owned work. The
`max_concurrency` option bounds Flow work; it is not a limit on all helper
processes or all children shared by several executions.

### Beta Migration

Replace `jido: MyApp.Jido` with
`task_supervisor: MyApp.Jido.TaskSupervisor` if the host keeps that name.
Remove `jido: nil` to use the default. This also applies to deprecated
`Instruction.opts`; Exec rejects `jido` there even when a new route is supplied
at the call. `Jido.Exec.task_supervisor_name(instance)` has been removed. Declare the
supervisor name in the host supervision tree, as shown above.

This rejection applies only to execution options. `context.jido` remains
ordinary host data and is preserved through nested Flows and continuations.

A host with several statically named instances can keep its own naming helper:

```elixir
def task_supervisor_name(nil), do: Jido.Exec.TaskSupervisor
def task_supervisor_name(instance), do: Module.concat(instance, TaskSupervisor)
```

Use that helper only with host-controlled instance atoms. For runtime tenant
keys, register supervisors through Registry or use PartitionSupervisor. Exec
needs only the resulting reference.

## Policy Boundary

This package does not accept options for automatic retry, retry backoff,
per-node timeout, step-wise deadline, durable cancellation, rewind, persistent
checkpoint, or recovery. Async handles provide owner-bound cancellation for
one in-memory call. Place durable policies in the caller or a higher-level
runtime.
