# FAQ

## What Is An Action?

An action is a leaf operation: a named module with Zoi validation and a `run/2` callback.

## Which Schemas Are Supported?

Action `schema` and `output_schema` accept Zoi schemas. Empty validation can be represented by omitting the option or using `[]`.

## Should I Call `run/2` Directly?

Yes, for one action. Validate params and output explicitly when that boundary matters.

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

## Where Should Higher-Level Orchestration Live?

Keep higher-level orchestration, adapter-specific conversions, bundled domain actions, agent strategy, and signal handling in separate packages.
