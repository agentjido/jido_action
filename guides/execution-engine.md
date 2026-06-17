# Execution Engine

`Jido.Exec` runs one action, or one `%Jido.Instruction{}`, with validation, timeout handling, retry policy, output validation, telemetry, and crash normalization.

## Synchronous Execution

```elixir
Jido.Exec.run(MyAction, params, context, timeout: 1_000, max_retries: 1)
```

Or execute a call frame:

```elixir
instruction = %Jido.Instruction{
  action: MyAction,
  params: params,
  context: context,
  opts: [timeout: 1_000]
}

Jido.Exec.run(instruction)
```

Execution order:

1. Validate params with `action.validate_params/1`.
2. Apply timeout budget and context propagation.
3. Call `action.run/2`.
4. Normalize exits, throws, exceptions, and invalid return shapes.
5. Retry retryable failures when policy allows it.
6. Validate successful output with `action.validate_output/1`.

## Options

- `:timeout` - maximum runtime in milliseconds. Use `0` to run directly without supervised timeout wrapping.
- `:max_retries` - retry attempts after the first failure.
- `:backoff` - initial retry delay in milliseconds; each retry doubles the delay and caps it.
- `:log_level` - execution logging level.
- `:jido` - instance namespace for isolated supervisors.
- `:context_propagators` - modules that capture and reattach runtime context.
- `:context_propagator_failure_mode` - `:warn` or `:strict`.

## Async Execution

```elixir
ref = Jido.Exec.run_async(MyAction, params, context, timeout: 5_000)
result = Jido.Exec.await(ref, 5_000)
```

`await/1` uses the configured default timeout. `await/2` uses the timeout passed by the caller. `cancel/1` shuts down a still-running async action and cleans monitor messages.

## Retry

Retry is controlled by `:max_retries` and `:backoff`.

```elixir
Jido.Exec.run(MyAction, params, %{}, max_retries: 3, backoff: 100)
```

Validation and configuration errors are not retryable. Timeout, internal, and execution failures are retryable unless their details explicitly say otherwise.

## Timeout And Deadline

Timeouts are enforced through supervised task execution. When a context already carries an execution deadline, `Jido.Exec` uses the smaller remaining budget.

On timeout, execution returns `Jido.Action.Error.TimeoutError`.

## Telemetry

Execution emits telemetry events for action start, stop, errors, retry decisions, and async execution. Event payloads are sanitized before logging or emission.

## Return Shapes

Valid action returns are:

- `{:ok, result}`
- `{:ok, result, extra}`
- `{:error, reason}`
- `{:error, reason, extra}`

Unexpected return values become `Jido.Action.Error.ExecutionFailureError`.
