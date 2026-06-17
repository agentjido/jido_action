# Configuration

Most execution policy can be passed directly to `Jido.Exec.run/4` or `run_async/4`. Application configuration supplies defaults.

## Execution Defaults

```elixir
config :jido_action,
  default_timeout: 30_000,
  default_max_retries: 1,
  default_backoff: 250,
  default_log_level: :info
```

- `:default_timeout` - runtime budget in milliseconds.
- `:default_max_retries` - retry attempts after the initial run.
- `:default_backoff` - initial retry delay in milliseconds.
- `:default_log_level` - default execution log level.

Invalid numeric config values fall back to built-in defaults.

## Per-Call Overrides

```elixir
Jido.Exec.run(
  MyAction,
  params,
  context,
  timeout: 2_000,
  max_retries: 0,
  backoff: 100,
  log_level: :debug
)
```

Per-call options win over application defaults.

## Context Propagation

Configure process-local runtime context propagation globally:

```elixir
config :jido_action, :observability,
  context_propagators: [MyApp.TraceContext],
  context_propagator_failure_mode: :warn
```

Or per call:

```elixir
Jido.Exec.run(
  MyAction,
  params,
  context,
  context_propagators: [MyApp.TraceContext],
  context_propagator_failure_mode: :strict
)
```

Propagators implement `Jido.Exec.ContextPropagator`.

## Instance Isolation

Pass `:jido` when an application needs isolated supervisors for a specific runtime instance:

```elixir
Jido.Exec.run(MyAction, params, context, jido: MyApp.RuntimeInstance)
```

