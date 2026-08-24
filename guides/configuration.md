# Configuration

Actions and Flow artifacts describe work and data contracts. They do not
store runtime policy. Configure Flow execution at the `Jido.Exec` boundary.

## Flow Execution Options

The current public API accepts exactly two Flow options:

```elixir
Jido.Exec.run(MyApp.Flows.BuildReport, input, context,
  async: true,
  max_concurrency: 4
)
```

| Option | Default | Validation | Scope |
| --- | --- | --- | --- |
| `async` | `false` | Must be a Boolean. | Enables concurrent independent nodes and concurrent Map item calls. |
| `max_concurrency` | `System.schedulers_online()` | Must be a positive integer. | Limits active Action calls across one in-memory execution when `async: true`. |

The `max_concurrency` default is stored on the execution even when `async` is
`false`. The option has no effect until asynchronous scheduling is enabled.
Reduce item calls and Iterate iterations always stay serial.

Pass the options to `run/4` or `start/4`:

```elixir
{:ok, result} =
  Jido.Exec.run(MyApp.Flows.BuildReport, input, context,
    async: true,
    max_concurrency: 2
  )

{:ok, execution} =
  Jido.Exec.start(MyApp.Flows.BuildReport, input, context,
    async: true,
    max_concurrency: 2
  )
```

Unknown options are rejected. A non-Boolean `async` value or a non-positive
`max_concurrency` value is rejected before execution starts.

## Scope And Nested Flows

Options belong to the execution created by the current `run/4` or `start/4`
call. They schedule independent nodes and internal Map items in that Flow.
The limit is local to that execution. One shared permit budget bounds active
Action validation and callback work across ready waves, concurrent Map nodes,
and nested Flow targets. Internal scheduling boundaries can create waiting
helper tasks, but they cannot start more Action calls than the shared limit.
The options do not change Flow dependencies.

A nested Flow runs as one atomic parent node and uses its own default execution
policy. The parent does not enable concurrent node scheduling inside the child,
but child Action calls share the parent's permit budget. Run the nested Flow
directly when it needs its own `async` scheduling policy.

## Current Policy Limits

The public Flow API does not currently accept options for:

- retries or retry backoff;
- per-node timeouts or Flow deadlines;
- cancellation or rewind; or
- persistent checkpoints or restart-safe resume.

Place these policies in the caller or a higher-level runtime package. Do not
add them to the Flow artifact or pass them as unknown `Jido.Exec` options.

See [Executing Flows](flow-execution.livemd) for run-to-completion, waves,
step-wise execution, failures, and nested Flow behavior.
