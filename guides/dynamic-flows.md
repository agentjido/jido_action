# Dynamic Flows

A dynamic Flow can select the next Action or Flow from runtime data. Use a
terminal `dispatch` component when the current Flow must make that selection.

Dispatch uses Runic's public dynamic graph behavior. The decision and expander
run as Action nodes. When the expander selects another executable, Runic adds
the compiled target and schedules its Runnables.

Use `Jido.Flow.new/1` instead when application code must construct the graph
itself at runtime. See [Flow Data Definitions](flow-data.md).

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

A normal result completes the Flow. A continuation selects the Action or Flow
that Runic adds next.

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

## Use Action Modules For Dispatch

Dispatch uses Action modules for its decision and expander. The decision gets
the resolved Dispatch `params`. The expander gets the complete decision
result. Both targets can be handwritten or generated Action modules.
Flow does not accept inline bodies for either role.

## Dispatch Rules

Every Flow with Dispatch must follow these rules:

- The Flow has only one Dispatch.
- Dispatch is the last component.
- Flow output is the complete Dispatch result, such as `result("route")`.
- Only the expander can return `{:continue, input, target}`.
- The decision and all other Flow components cannot continue.
- The continuation form is valid only for a Dispatch expander.

These rules keep dynamic composition in an explicit Flow component.

## Output Validation And Effects

When the expander returns `{:ok, result}`, the current Flow owns the result and
applies its output schema. Decision and expander Actions can return an optional
third element with a proper list of effect requests. Flow collects decision
effects before expander effects.

When the expander returns a continuation, the selected executable owns final
output validation and the final output. Earlier effects remain in the same
list, before the next executable's effects. Failure anywhere in the chain
returns no executable effects. See [Execution](execution.md#results-and-errors).

A continuation selects the next executable:

```elixir
def run(params, _context) do
  {:continue, params, MyApp.Actions.Finalize}
end
```

Do not start a nested `Jido.Exec` call from the expander. Return the Dispatch
continuation so Runic owns the complete graph.

## Define Dispatch With Data

All Flow authoring forms produce the same canonical Dispatch node.

```elixir
{:ok, flow} =
  Jido.Flow.new(%{
    output: Jido.Flow.Ref.result("route"),
    components: [
      %{
        kind: :dispatch,
        name: "route",
        decision: MyApp.Actions.ChooseRoute,
        expander: MyApp.Actions.ExpandRoute,
        params: %{mode: Jido.Flow.Ref.input(:mode), value: Jido.Flow.Ref.input(:value)}
      }
    ],
    name: "dynamic_route"
  })
```

Use `Jido.Flow.new/1` for map definitions. Use `Jido.Flow.Codec` and a trusted
Registry when stored JSON defines the Flow.

## Build A Bounded Loop

Use an Iterate component for a bounded loop. Iterate keeps explicit state,
checks a declarative completion expression, and requires `max_iterations`.
Each body call is a normal Action node and each iteration is part of Runic's
durable execution state.

A root Action cannot select another executable through `{:continue, ...}`.
Use Dispatch when runtime data must select the next Action or Flow.
