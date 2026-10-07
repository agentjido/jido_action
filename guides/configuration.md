# Runtime Configuration

Runtime policy belongs to Runic. `Jido.Exec` accepts a small option set and
converts it to Runic policy or Runner options.

## Immediate Execution

`Jido.Exec.run/4` accepts:

| Option | Default | Rule |
| --- | --- | --- |
| `timeout` | `:infinity` | Per-attempt timeout or `:infinity`. |
| `max_attempts` | `1` | Positive integer. |
| `backoff` | `:none` | `:none`, `:linear`, `:exponential`, or `:jitter`. |
| `base_delay_ms` | `0` | Non-negative integer. |
| `max_delay_ms` | `0` | Non-negative integer. |
| `max_concurrency` | `1` | Positive integer. |

```elixir
Jido.Exec.run(MyApp.Flows.BuildReport, input, context,
  timeout: 10_000,
  max_attempts: 3,
  backoff: :exponential,
  base_delay_ms: 50,
  max_delay_ms: 2_000,
  max_concurrency: 4
)
```

The timeout applies to each Runnable attempt. Runic owns retries and backoff.
Unknown or malformed options return a configuration error.

## Managed Execution

`Jido.Exec.start/6` accepts the policy options above and these Runic Worker
options:

- `max_concurrency`
- `on_complete`
- `checkpoint_strategy`
- `executor` and `executor_opts`
- `scheduler` and `scheduler_opts`
- `hooks`
- `promise_opts`

Managed execution uses durable Runic policy. If no executor is supplied, the
default Exec adapter uses the Runner's Task supervisor.

```elixir
Jido.Exec.start(
  MyApp.Runner,
  "report-42",
  MyApp.Flows.BuildReport,
  input,
  context,
  timeout: 10_000,
  max_attempts: 3,
  max_concurrency: 4,
  checkpoint_strategy: :every_cycle
)
```

Configure the Store, Scheduler, Executor, and supervision tree on
`Runic.Runner`. Use `Runic.Runner` directly for checkpoint, stop, resume, and
result inspection.

## Portability

Managed execution rejects process-local Instruction parameters and context,
such as PIDs, ports, references, and functions. Immediate execution can use
local values. Durable Action outputs must also be portable before Runic stores
them.
