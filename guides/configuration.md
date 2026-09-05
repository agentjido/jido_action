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

The host owns the Task.Supervisor, its capacity, and its shutdown policy.
Pass a local PID, registered name, or `{:via, module, name}` reference. Omit
`task_supervisor` to use `Jido.Exec.TaskSupervisor`.

```elixir
# Add this child to the application supervision tree.
{Task.Supervisor, name: MyApp.ReportTasks, max_children: 1_000}

Jido.Exec.run(MyApp.Flows.BuildReport, input, context,
  task_supervisor: MyApp.ReportTasks
)
```

For partitioned supervision, start a PartitionSupervisor with Task.Supervisor
children and pass a route selected by the caller:

```elixir
{PartitionSupervisor, child_spec: Task.Supervisor, name: MyApp.ReportPartitions}

route = {:via, PartitionSupervisor, {MyApp.ReportPartitions, self()}}
Jido.Exec.run(MyApp.Flows.BuildReport, input, context, task_supervisor: route)
```

Exec keeps the same reference and partition key through nested work and
continuations. Names and via routes resolve at each task start, so later work
can use a replacement supervisor. A PID selects only that process.

The supervisor must be local; `nil`, remote references, and `:global` routes
are invalid. Missing supervisors and task-start failures produce structured
errors. Exec does not fall back to another supervisor or restart interrupted
work. Failure details include the supplied `task_supervisor` and `reason`.

The supervisor owns Action workers and async control tasks. An async call
needs a control slot in addition to its Action worker slots. `run_async/4`
raises `InvalidInputError` for invalid routing or `AsyncExecutionError` if its
control task cannot start. After it returns a handle, failures use the normal
async result contract.

`max_concurrency` limits Flow work, not every helper process or all callers
that share a supervisor. Context values, including `context.jido`, remain
caller data and do not select the supervisor.

## Policy Boundary

This package does not accept options for automatic retry, retry backoff,
per-node timeout, step-wise deadline, durable cancellation, rewind, persistent
checkpoint, or recovery. Async handles provide owner-bound cancellation for
one in-memory call. Place durable policies in the caller or a higher-level
runtime.
