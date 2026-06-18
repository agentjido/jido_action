# FAQ

## What Is An Action?

An action is a leaf operation: a named module with Zoi validation and a `run/2` callback.

## Which Schemas Are Supported?

Action `schema` and `output_schema` accept Zoi schemas. Empty validation can be represented by omitting the option or using `[]`.

## Should I Call `run/2` Directly?

Yes, for one action. Validate params and output explicitly when that boundary matters. Use `Jido.Flow` plus `Jido.Exec.run/3` when you need Runic runtime policy.

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

Retries are Runic scheduler policy. Use `Jido.Flow.policy/3` for named flow components or pass runtime `:scheduler_policies` to `Jido.Exec.run/3`.

## Where Should Higher-Level Orchestration Live?

Use `Jido.Flow` for in-package composition of leaf actions and native Runic stateful components. Keep adapter-specific conversions, bundled domain actions, agent strategy, and signal handling in separate packages.
