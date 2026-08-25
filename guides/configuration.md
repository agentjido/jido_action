# Runtime Configuration

Actions and Flows define work and data. Runtime policy belongs to
`Jido.Exec.run/4` or `Jido.Exec.start/4`.

## Common Run Options

All resolved targets accept these options in `run/4`:

| Option | Default | Rule |
| --- | --- | --- |
| `timeout` | `:infinity` | `:infinity` or a non-negative millisecond integer. |
| `jido` | `nil` | A Jido instance module or `nil`. |

A finite timeout covers the complete call. It terminates the execution process
and active child work. It does not retry the target.

`start/4` accepts `jido` but not `timeout`. A paused step-wise execution does
not have one complete-call clock.

## Flow Scheduling Options

Flow modules, Flow values, and Flow Instructions also accept:

| Option | Default | Rule |
| --- | --- | --- |
| `async` | `false` | Must be a Boolean. |
| `max_concurrency` | `System.schedulers_online()` | Must be a positive integer. |

`async: true` permits independent ready Runic work and Map items to run
concurrently. One shared budget limits active Action calls across nodes,
collections, and nested Flows. A separate budget limits helper workers.
Nested work runs inline when no helper-worker slot is available.

Reduce and Iterate Action work stays serial.

```elixir
Jido.Exec.run(
  MyApp.Flows.BuildReport,
  input,
  context,
  timeout: 10_000,
  async: true,
  max_concurrency: 4
)
```

Unknown options are errors. An Action target rejects `async` and
`max_concurrency`. An Instruction follows the option rules of its target.

## Jido Instance Routing

`jido: MyApp.Jido` routes Action workers through
`MyApp.Jido.TaskSupervisor`.

```elixir
Jido.Exec.run(
  MyApp.Flows.BuildReport,
  input,
  context,
  jido: MyApp.Jido,
  async: true,
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
per-node timeout, step-wise deadline, public cancellation, rewind, persistent
checkpoint, or recovery. Place these policies in the caller or a higher-level
runtime.
