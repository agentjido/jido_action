# FAQ

## What Is An Action?

An action is a leaf operation: a named module with Zoi validation and a `run/2` callback.

## Which Schemas Are Supported?

Action `schema` and `output_schema` accept Zoi schemas. Empty validation can be represented by omitting the option or using `[]`.

## Should I Call `run/2` Directly?

Direct calls are fine for narrow unit tests. Use `Jido.Exec.run/4` for production paths and integration tests that need validation, retries, timeout handling, telemetry, output validation, or crash normalization.

## How Do I Add Optional Params?

Use `Zoi.optional/1` when a missing value should remain absent.

```elixir
Zoi.object(%{nickname: Zoi.string() |> Zoi.optional()})
```

Use `Zoi.default/2` when the action should receive a value even if the caller omits it.

```elixir
Zoi.object(%{limit: Zoi.integer() |> Zoi.default(50)})
```

## Are Unknown Keys Rejected?

No. Unknown keys are preserved and merged back into the validated map. Only declared keys are validated.

## How Do Retries Work?

`Jido.Exec` retries retryable failures while `:max_retries` allows it. Validation and configuration errors are not retryable. Timeout and execution failures usually are retryable.

## How Do I Preserve Request Context In Async Execution?

Pass needed data in the `context` map. For process-local state such as tracing context, configure modules that implement `Jido.Exec.ContextPropagator`.

## Where Should Higher-Level Orchestration Live?

Use `Jido.Flow` for in-package composition of leaf actions and native Runic stateful components. Keep adapter-specific conversions, bundled domain actions, agent strategy, and signal handling in separate packages.
