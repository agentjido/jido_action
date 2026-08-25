# Configuration

Actions and Flow artifacts describe work and data contracts. They do not
store runtime policy. Configure Flow execution at the `Jido.Exec` boundary.

## Flow Policy Options

The current public API accepts two Flow scheduling options:

```elixir
Jido.Exec.run(MyApp.Flows.BuildReport, input, context,
  async: true,
  max_concurrency: 4
)
```

| Option | Default | Validation | Scope |
| --- | --- | --- | --- |
| `async` | `false` | Must be a Boolean. | Enables concurrent independent nodes and concurrent Map item calls. |
| `max_concurrency` | `System.schedulers_online()` | Must be a positive integer. | Limits active Action calls and asynchronous helper workers across one in-memory execution when `async: true`. |

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

`run/4` also accepts the common `jido:` routing option and one complete-call
`timeout:` option. `start/4` accepts `jido:`, but it rejects `timeout:` because
step-wise execution does not start one complete-call clock.

## Jido Instance Routing

Actions, Instructions, and Flows accept the common `jido:` routing option:

```elixir
Jido.Exec.run(MyApp.Flows.BuildReport, input, context,
  jido: MyApp.Jido,
  async: true,
  max_concurrency: 4
)
```

This routes every Action worker in the call, including nested Flow work,
through `MyApp.Jido.TaskSupervisor`. This name matches the Jido core instance
contract. Start the Jido instance in the application supervision tree before
the call. If the selected Task Supervisor is not running, Exec returns a
structured error and does not use its global supervisor.

When `:jido` is absent or `nil`, Exec uses `Jido.Exec.TaskSupervisor`. The
short-lived Flow concurrency limiter stays in the global Exec supervision
tree. It is isolated by the unique Flow execution ID.

## Scope And Nested Flows

Options belong to the execution created by the current `run/4` or `start/4`
call. They schedule independent nodes and internal Map items in that Flow.
The limit is local to that execution. One shared permit budget bounds active
Action validation and callback work across ready waves, concurrent Map nodes,
and nested Flow targets. A second non-blocking budget bounds asynchronous
helper workers. Nested scheduling runs work inline when no helper-worker slot
is available. Thus, it does not create helper processes that wait for a slot.
The options do not change Flow dependencies.

A nested Flow compiles as a native Runic Workflow boundary and inherits
`async`, `max_concurrency`, and `jido` from the parent execution. Its Action
calls use the selected instance Task Supervisor and the same execution-wide
budgets. The native ready set can expose child validators, child Steps, and
connection work.

## Current Policy Limits

The public Flow API does not currently accept options for:

- retries or retry backoff;
- per-node timeouts or step-wise Flow deadlines;
- cancellation or rewind; or
- persistent checkpoints or restart-safe resume.

`Jido.Exec.run/4` accepts one `timeout:` for the complete Action, Instruction,
or Flow call. The default is `:infinity`.

Place these policies in the caller or a higher-level runtime package. Do not
add them to the Flow artifact or pass them as unknown `Jido.Exec` options.

See [Executing Flows](flow-execution.livemd) for run-to-completion, waves,
step-wise execution, failures, and nested Flow behavior.
