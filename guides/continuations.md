# Action And Flow Continuations

A continuation lets an Action request the next executable during one
run-to-completion call. Use it when the next Action or Flow depends on a result
that is available only at runtime.

## Return A Continuation

An Action can return:

```elixir
{:continue, continuation_input, continuation_target}
```

`continuation_input` must be a map. `continuation_target` must be one of:

- an Action module;
- a Flow module; or
- a `%Jido.Flow{}` value.

The target receives the current Action context. Its effective result becomes
the result of the Action that returned `:continue`. Jido validates this final
result against the output schema of that Action.

```elixir
defmodule MyApp.Actions.SelectTool do
  use Jido.Action,
    name: "select_tool",
    output_schema: Zoi.object(%{temperature: Zoi.number()})

  @impl true
  def run(%{tool: "weather", arguments: arguments}, _context) do
    {:continue, arguments, MyApp.Actions.GetWeather}
  end
end
```

Do not return an Instruction, a function, or a raw Runic value as the target.
Resolve untrusted names through a fixed application catalog before you return
a continuation.

If the runtime result requires multiple Actions, build or select one Flow and
return that Flow as the target. Do not return a list of work requests.

## Execution Order

A Flow continuation expands the live Runic graph. The target runs before the
authored downstream component can use the originating result.

```text
origin Action -> continuation target -> effective origin result -> downstream work
```

The continuation tuple is private execution control. It does not become a
Flow result, Action extras, a Signal, a Directive, or a second input queue.
`Jido.Exec.workflow/1` shows the expanded live graph.
`Jido.Exec.compiled/1` keeps the authored compilation.

## Use A Dynamic Component

`Jido.Flow.Dynamic` defines a bounded decision and expansion loop. The
decision output becomes the expander input. A normal expander result closes
the component. If the expander returns a continuation, Jido runs its target
and sends the effective result to the next decision call.

```elixir
defmodule MyApp.Flows.ReasonAndAct do
  use Jido.Flow, name: "reason_and_act"

  flow do
    dynamic "reason" do
      decision(MyApp.Actions.DecideNextStep)
      expander(MyApp.Actions.ExpandDecision)
      params(%{messages: input(:messages)})
      max_continuations(8)
    end

    output(result("reason"))
  end
end
```

The local `max_continuations` value is required. It bounds continuation cycles
for this Dynamic component.

Direct construction uses `Jido.Flow.Dynamic.new/1`. Runtime construction uses
`Jido.Flow.Builder.dynamic/6`. Stored version 1 Flow data supports the same
component through `Jido.Flow.Codec`.

## Set The Execution Bound

All `Jido.Exec.run/4` and `run_async/4` targets accept
`max_continuations`. The default is `32`. The valid range is 0 through 10,000.
A value of `0` rejects all continuations. One counter covers nested Action and
Flow continuations in the complete execution.

```elixir
Jido.Exec.run(MyApp.Actions.SelectTool, input, context,
  max_continuations: 8,
  max_concurrency: 4
)
```

`max_concurrency` is also available for all targets because a direct Action
can continue into a Flow.

## Use Async Results In An OTP Process

Use `Jido.Exec.handle_message/2` to classify messages for an async handle.
Only the process that created the handle can use it.

```elixir
def handle_info(message, %{handle: handle} = state) do
  case Jido.Exec.handle_message(handle, message) do
    {:done, result} -> {:noreply, %{state | handle: nil, result: result}}
    :ignore -> {:noreply, state}
    {:error, error} -> {:stop, error, state}
  end
end
```

The handle is one-shot. `await/2`, `cancel/1`, and `handle_message/2` share the
same ownership and completion state.

## Inspect Continuation Lineage

For step-wise Flow execution, use `Jido.Exec.continuations/1`. It returns
ordered records with sequence, occurrence, parent, depth, kind, target
identity, origin, and graph node data. It does not expose continuation input,
target arguments, or output values.

