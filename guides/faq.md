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

The current Flow execution API does not provide retry options. Retries belong
to the caller or a higher-level runtime package.

## When Should I Use A Flow?

Use a Flow when several actions form one validated graph with a declared return
value. Use an Instruction when you need data that describes one action call.

## How Do I Add Conditional Routing?

Use a Flow Choice. `choose` tests named options in authored order and runs the
first match. `otherwise` is required and runs when no option matches.

A Choice fallback is a routing fallback. It is not an error handler for a
target that already failed. See [Flow Choices](flow-choices.md).

## Can I Step Through A Flow?

Yes. Start a paused execution with `Jido.Exec.start/4`, inspect named ready
nodes with `ready/1`, and use `step/1`, `step/2`, or `wave/1` to advance it.
Use `continue/1` to finish and `result/1` to read the cached result.

Always pass the latest returned execution value to the next operation. Reusing
an older value can run an action more than once. See
[Executing Flows](flow-execution.md).

## Can A Flow Run Nodes In Parallel?

Yes. Pass `async: true` and `max_concurrency: positive_integer` to
`Jido.Exec.run/4` or `Jido.Exec.start/4`. Only independent nodes in the same
ready wave can overlap.

## Do Flows Support Timeouts Or Persistent Resume?

Not in the current public API. Flow run options support `async` and
`max_concurrency`. Executions are in-memory values. They do not provide
timeouts, deadlines, cancellation, rewind, persistent checkpoints, or
restart-safe resume.

## Where Should Higher-Level Orchestration Live?

Keep higher-level orchestration, adapter-specific conversions, bundled domain
actions, agent strategy, and signal handling in separate packages. Use
`Jido.Flow` for explicit action composition inside this package boundary.
