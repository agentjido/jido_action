# Dynamic Flows With Dispatch

Most Flows have a fixed shape. A dynamic Flow lets runtime data choose the
next Action or Flow while the Flow runs. Use a `dispatch` component at the end
of a Flow for that choice.

Pick the right tool:

- Use [`choice`](flow-choices.livemd) when the possible targets are known
  when you write the Flow.
- Use `dispatch` when an Action must decide the target at runtime.
- Use [`Jido.Flow.new/1`](flow-data.md) when your code must build the whole
  graph from data before it runs.

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

A normal result completes the Flow. A continuation runs the selected Action or
Flow next, with `next_input` as its params. The selected target's result
becomes the Dispatch result.

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

Target selection is application code. Only select trusted targets. Map a
stored or user-supplied name to a module through an application-owned
registry; never convert input to a module name.

In this example, `params` reads `input(:target)` on every call. A call
without a `:target` key fails with a missing reference error, even in
`:finish` mode. Supply every key that the Dispatch params read.

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
returns no executable effects. See [Outputs And Effects](action-effects.livemd).

A continuation selects the next executable:

```elixir
def run(params, _context) do
  {:continue, params, MyApp.Actions.Finalize}
end
```

Do not start a nested `Jido.Exec` call from the expander. Return the
continuation instead, so the selected target runs inside the same execution
with the same options, telemetry, and effect list.

A selected target cannot continue again. A continuation is one hop.

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

## Loops

Dispatch selects one more target; it does not loop. Use an
[`iterate`](flow-iterate-state.livemd) component for bounded repetition.
