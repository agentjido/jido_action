# FAQ

## What Is An Action?

An action is a leaf operation: a named module with Zoi validation and a `run/2` callback.

## Which Schemas Are Supported?

Action `schema` and `output_schema` accept Zoi schemas. Empty validation can be represented by omitting the option or using `[]`.

## Should I Call `run/2` Directly?

Use a direct `run/2` call for focused action logic and unit tests. Use
`Jido.Exec.run/3` for the public execution boundary. `Jido.Exec` validates
input and output and normalizes action failures.

## When Should I Use An Instruction?

Use `Jido.Instruction` when one action call must exist as data before
execution. It stores the action, params, and context. It does not store runtime
policy or a workflow.

## When Should I Use A Flow?

Use `Jido.Flow` when several action calls form one static dependency graph with
one declared return expression. Use an instruction for one action call.

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

Retries belong to the caller or higher-level package that executes actions.

## Can Flow Branches Run Concurrently?

Yes. Flow execution is serial by default. Pass `async: true` and a positive
`max_concurrency` value to `Jido.Exec.run/4` to schedule independent branches
concurrently.

## Where Should Higher-Level Orchestration Live?

Keep higher-level orchestration, adapter-specific conversions, bundled domain actions, agent strategy, and signal handling in separate packages.
