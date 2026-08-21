# Configuration

`jido_action` does not own runtime policy configuration in this foundation.

Configure retries, timeouts, scheduling, context propagation, and supervision in
the caller or higher-level package that executes actions.

Flow concurrency is a per-call option at the `Jido.Exec` boundary:

```elixir
Jido.Exec.run(flow, input, context, async: true, max_concurrency: 4)
```

Action and instruction execution do not accept run options.
