# Terminal Transitions

An Action can end its current executable and select the next executable:

```elixir
def run(%{tool: tool, arguments: arguments}, _context) do
  {:continue, arguments, tool}
end
```

The tuple has three values:

- `input` is a map for the next executable.
- `target` is an Action or Flow module, or a runtime Flow value.
- The current context passes to the target without a change.

This result is a terminal transition. It does not add work to the current Flow,
resume a component, or change the Runic graph. The current executable is done.
The final target owns output validation, extras, and the final return value.

Target resolution is part of the current executable's transition boundary. If
the complete-call timeout expires before the target descriptor resolves, the
timeout error belongs to the current executable. After resolution, the target
owns its execution timeout and lifecycle. An unresolved initial module target
uses the Action timeout type until its descriptor resolves.

## Dynamic Flow Boundary

Use `Jido.Flow.Dynamic` when a Flow must calculate its next executable:

```elixir
dynamic :select_tool,
  decision: MyApp.ChooseTool,
  expander: MyApp.ExpandToolCall,
  params: %{request: input(:request)}

output result(:select_tool)
```

The decision Action returns data. Dynamic gives that data to the expander
Action. The expander has two valid choices:

```elixir
{:ok, final_flow_result}
{:continue, next_input, next_executable}
```

A normal result closes the Flow. A continuation closes the Flow and lets the
outer Exec call run the selected executable.

The boundary has these rules:

- A Flow has zero or one Dynamic component.
- Dynamic is the sole terminal component.
- The Flow output is exactly the complete Dynamic result.
- Only the Dynamic expander can continue from inside a Flow.
- A Dynamic decision and all other Flow positions cannot continue.
- Step-wise execution and Subflow use reject Dynamic.

These rules make continuation a terminal state change. They do not make it a
general graph operation.

## Loop Safety

Each `Jido.Exec.run/4` call has one continuation budget for its complete Action
and Flow chain. `max_continuations` defaults to `32` and accepts values from `0`
through `10_000`.

```elixir
Jido.Exec.run(MyApp.Reason, input, context,
  max_continuations: 12,
  timeout: 30_000
)
```

Exec returns a structured error when the next transition would exceed the
budget. A finite `timeout` covers the same complete chain and stops slow work.
Use both limits for a reasoning loop: one bounds the number of transitions,
and one bounds elapsed time.

`Jido.Exec.run_async/4` runs the same bounded chain. The handle represents the
complete chain, not one Action.
