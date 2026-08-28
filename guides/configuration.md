# Runtime Configuration

Actions and Flows define work and data. Runtime policy belongs to
`Jido.Exec.run/4` or `Jido.Exec.start/4`.

## Common Run Options

All resolved targets accept these options in `run/4`:

| Option | Default | Rule |
| --- | --- | --- |
| `timeout` | `:infinity` | `:infinity` or a non-negative millisecond integer. |
| `jido` | `nil` | A Jido instance module or `nil`. |
| `max_concurrency` | `8` | A positive integer. |
| `max_continuations` | `32` | An integer from 0 through 10,000. |

A finite timeout covers the complete call. It terminates the execution process
and active child work. It does not retry the target.

`start/4` accepts `jido` but not `timeout`. A paused step-wise execution does
not have one complete-call clock. Use `continue/1` to run it to completion.

## Flow Scheduling Options

`max_concurrency: 1` runs ready work serially. A value greater than `1`
dispatches independent work concurrently and bounds the tasks in that wave.
Map items are native Runic runnables and use the same rule. There is no second
Jido concurrency budget.

All targets accept this option because an Action can continue into a Flow.
`max_continuations` bounds all nested continuations in one complete execution.

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

Unknown options are errors. An Instruction follows the option rules of its
target. The removed Flow `async:` option is an unknown option.

## Jido Instance Routing

`jido: MyApp.Jido` routes Action workers through
`MyApp.Jido.TaskSupervisor`.

```elixir
Jido.Exec.run(
  MyApp.Flows.BuildReport,
  input,
  context,
  jido: MyApp.Jido,
  max_concurrency: 4
)
```

The Jido instance must be running. Exec returns a structured error if the
named Task Supervisor does not exist. It does not fall back to the global
supervisor.

When `jido` is absent or `nil`, Exec uses `Jido.Exec.TaskSupervisor`.

Nested Flows inherit the routing and scheduling options. Options do not change
Flow dependencies.

## Policy Boundary

This package does not accept options for automatic retry, retry backoff,
per-node timeout, step-wise deadline, durable cancellation, rewind, persistent
checkpoint, or recovery. Async handles provide owner-bound cancellation for
one in-memory call. Place durable policies in the caller or a higher-level
runtime.
