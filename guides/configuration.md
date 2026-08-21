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
| `async` | `false` | Must be a Boolean. | Controls whether independent nodes in the current ready wave can run concurrently. |
| `max_concurrency` | `System.schedulers_online()` | Must be a positive integer. | Limits concurrent node tasks when `async: true` in the current Flow execution. |

The `max_concurrency` default is stored on the execution even when `async` is
`false`. The option has no effect until asynchronous scheduling is enabled.

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
call. They schedule independent nodes in that Flow only. They do not change
Flow dependencies, and they do not propagate into nested Flow targets.

A nested Flow runs as one atomic parent node and uses its own default execution
policy. Run the nested Flow directly when it needs its own `async` or
`max_concurrency` settings.

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
