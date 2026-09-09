# Dynamic Flows

A dynamic Flow can select the next Action or Flow from runtime data. Use a
terminal `Jido.Flow.Dispatch` when the current Flow must make that selection.

Dispatch does not add a node to a running graph or change the current graph.
It completes the current Flow, then its expander can continue the same
`Jido.Exec` call with another executable.

Use `Jido.Flow.Builder` instead when application code must construct the graph
itself at runtime. See [Direct Construction And Builder](flow-builder.md).

## How Dispatch Works

A Dispatch has two Actions:

1. The decision Action receives the Dispatch parameters and returns a map.
2. The expander Action receives that complete map.
3. The expander returns a final result or selects the next executable.

The expander can return either form:

```elixir
{:ok, final_result}
{:continue, next_input, next_executable}
```

A normal result completes the Flow. A continuation completes the Flow and runs
the selected Action or Flow next. The same context, timeout, and continuation
budget apply to the complete chain.

## Define A Dispatch

This example asks one Action to select a route. A second Action converts that
decision into a final result or a continuation.

```elixir
defmodule MyApp.Actions.ChooseRoute do
  use Jido.Action, name: "choose_route"

  @impl true
  def run(%{mode: :finish, value: value}, _context) do
    {:ok, %{route: :finish, value: value}}
  end

  def run(%{mode: :continue, value: value, target: target}, _context) do
    {:ok, %{route: :continue, value: value, target: target}}
  end
end

defmodule MyApp.Actions.ExpandRoute do
  use Jido.Action, name: "expand_route"

  @impl true
  def run(%{route: :finish, value: value}, _context) do
    {:ok, %{value: value}}
  end

  def run(%{route: :continue, value: value, target: target}, _context) do
    {:continue, %{value: value}, target}
  end
end

defmodule MyApp.Flows.DynamicRoute do
  use Jido.Flow, name: "dynamic_route"

  flow do
    step "prepare", value <- input(:value) do
      {:ok, %{value: value}}
    end

    dispatch "route",
      decision: MyApp.Actions.ChooseRoute,
      expander: MyApp.Actions.ExpandRoute,
      params: %{
        mode: input(:mode),
        target: input(:target),
        value: result("prepare", :value)
      }

    output result("route")
  end
end
```

The selected target can be an Action module, a Flow module, or a runtime
`%Jido.Flow{}` value:

```elixir
Jido.Exec.run(MyApp.Flows.DynamicRoute, %{
  mode: :continue,
  target: MyApp.Actions.Next,
  value: 3
})
```

Target selection is application code. Only select trusted executable values.
A stored name or external value must first pass through an application-owned
registry.

## Use Inline Decision And Expander Actions

Dispatch supports inline Actions when the logic belongs only to one Flow:

```elixir
defmodule MyApp.Flows.InlineDynamicRoute do
  use Jido.Flow, name: "inline_dynamic_route"

  flow do
    dispatch "route" do
      decision params <- input() do
        {:ok, params}
      end

      expander do
        %{done?: true, value: value} ->
          {:ok, %{value: value}}

        %{done?: false, value: value, target: target} ->
          {:continue, %{value: value}, target}
      end
    end

    output result("route")
  end
end
```

The decision uses bound mode because the Flow resolves its input expression.
The expander uses callback mode because it receives the complete decision
result. A headerless expander can use several clauses, as in this example.

See [Inline Actions](inline-actions.md) for schemas, context bindings, lookup,
and the complete inline syntax.

## Dispatch Rules

Every Flow with Dispatch must follow these rules:

- The Flow has only one Dispatch.
- Dispatch is the last component.
- Flow output is the complete Dispatch result, such as `result("route")`.
- Only the expander can return `{:continue, input, target}`.
- The decision and all other Flow components cannot continue.
- Dispatch works only with run-to-completion execution.
- A Flow with Dispatch cannot be used as a Subflow.

These rules make the boundary clear: the graph completes before another
executable starts.

## Output Validation And Extras

When the expander returns `{:ok, result}`, the current Flow owns the result and
applies its output schema. Extras returned by the decision or expander are
discarded like extras from other Flow nodes.

When the expander returns a continuation, the selected executable owns final
output validation, extras, and the return value. This pattern lets a final
Action return directives or other extras to a higher-level runtime:

```elixir
def run(params, _context) do
  {:continue, params, MyApp.Actions.Finalize}
end
```

Do not start a nested `Jido.Exec` call from the expander. Return a continuation
so one Exec call owns the complete chain.

## Build Dispatch Directly Or With Builder

All Flow authoring forms produce the same canonical Dispatch value.

```elixir
alias Jido.Flow.Builder

{:ok, flow} =
  Builder.new(name: "dynamic_route")
  |> Builder.dispatch(
    "route",
    MyApp.Actions.ChooseRoute,
    MyApp.Actions.ExpandRoute,
    %{mode: Builder.input(:mode), value: Builder.input(:value)}
  )
  |> Builder.output(Builder.result("route"))
  |> Builder.build()
```

Use `Jido.Flow.Dispatch.new/1` for direct canonical construction. Use
`Jido.Flow.Codec` and a trusted Registry when stored JSON defines the Flow.

## Build A Bounded Loop

A continued Action can return to the dynamic Flow. This supports tool loops
and other bounded decision cycles:

```elixir
defmodule MyApp.Actions.RunTool do
  use Jido.Action, name: "run_tool"

  @impl true
  def run(%{call: call, messages: messages}, context) do
    with {:ok, result} <- MyApp.Tools.call(call, context) do
      messages = messages ++ [%{role: :tool, content: result}]
      {:continue, %{messages: messages}, MyApp.Flows.Reason}
    end
  end
end
```

One `Jido.Exec.run/4` call owns the full chain. Set both limits for loops:

```elixir
Jido.Exec.run(MyApp.Flows.Reason, input, context,
  max_continuations: 12,
  timeout: 30_000
)
```

`max_continuations` defaults to `256` and accepts `0` through `10_000`. The
timeout covers the complete chain. `run_async/4` uses the same rules, and its
handle represents the complete chain.

## Continue From A Root Action

A root Action can also select the next executable without a Flow:

```elixir
def run(%{tool: tool, arguments: arguments}, _context) do
  {:continue, arguments, tool}
end
```

The input must be a map. The target can be an Action module, a Flow module, or
a runtime Flow value. The current context passes to the target without a
change.

The complete input cannot be a `Jido.Action.Output` envelope. Put an envelope
in a named map field when the next executable must receive it:

```elixir
{:continue, %{output: Jido.Action.Output.raw("complete")}, MyApp.Actions.Next}
```

Target resolution belongs to the current executable. If the complete-call
timeout expires before the target descriptor resolves, the timeout error
belongs to the current executable. After resolution, the selected target owns
its execution lifecycle.

Use Dispatch when earlier Flow work supplies the decision. Use a root Action
continuation when no graph is needed.
