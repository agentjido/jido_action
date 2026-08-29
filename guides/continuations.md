# Continue to Another Executable

An Action can choose what runs next:

```elixir
def run(%{tool: tool, arguments: arguments}, _context) do
  {:continue, arguments, tool}
end
```

The tuple has three values:

- `input` is a map for the next executable.
- `target` is an Action or Flow module, or a runtime Flow value.
- The current context passes to the target without a change.

The complete input cannot be a `Jido.Action.Output` envelope. Put the envelope
in a named map field if the next executable must receive it:

```elixir
{:continue, %{output: Jido.Action.Output.raw("complete")}, NextAction}
```

`Jido.Exec` finishes the current executable and runs the selected target next.
It does not add work to the current Flow, resume a component, or change the
Runic graph. The final target owns output validation, extras, and the final
return value.

Target resolution is part of the current executable. If the complete-call
timeout expires before the target descriptor resolves, the timeout error
belongs to the current executable. After resolution, the target owns its
execution timeout and lifecycle. An unresolved initial module target uses the
Action timeout type until its descriptor resolves.

## Continue from a Flow

Use `Jido.Flow.Dispatch` when a Flow must choose its result or what runs next:

```elixir
dispatch :select_tool,
  decision: MyApp.ChooseTool,
  expander: MyApp.ExpandToolCall,
  params: %{request: input(:request)}

output result(:select_tool)
```

The decision Action returns data. Dispatch gives that data to the expander
Action. The expander has two valid choices:

```elixir
{:ok, final_flow_result}
{:continue, next_input, next_executable}
```

A normal result finishes the Flow. A continuation finishes the Flow and lets
the Exec call run the selected executable next.

These rules apply:

- A Flow has zero or one Dispatch component.
- Dispatch is the last component in the Flow.
- The Flow output is exactly the complete Dispatch result.
- Only the Dispatch expander can continue from inside a Flow.
- The Dispatch decision and other Flow components cannot continue.
- Step-wise execution and Subflow use reject Dispatch.

Dispatch chooses the Flow result or the next executable. It does not change the
Flow graph.

## Example: an LLM Tool Loop

Use continuation when the result of the current work tells you what must run
next. For example, an LLM can return a final answer or ask the application to
call a tool.

The Dispatch expander handles that choice:

```elixir
defmodule MyApp.HandleLLMResponse do
  use Jido.Action, name: "handle_llm_response"

  def run(%{type: :answer, answer: answer}, _context) do
    {:ok, %{answer: answer}}
  end

  def run(%{type: :tool_call, tool_call: call, messages: messages}, _context) do
    {:continue, %{tool_call: call, messages: messages}, MyApp.RunTool}
  end
end
```

The tool Action runs the requested tool. It then sends the tool result back to
the reasoning Flow:

```elixir
defmodule MyApp.RunTool do
  use Jido.Action, name: "run_tool"

  def run(%{tool_call: call, messages: messages}, context) do
    with {:ok, tool_result} <- MyApp.Tools.call(call, context) do
      next_messages = messages ++ [%{role: :tool, content: tool_result}]
      {:continue, %{messages: next_messages}, MyApp.ReasonFlow}
    end
  end
end
```

The reasoning Flow can now ask the LLM again. The loop stops when the expander
returns `{:ok, result}`. One `Jido.Exec.run/4` call owns the full loop, so the
same timeout and continuation limit apply to every step.

## Loop Safety

Each `Jido.Exec.run/4` call has one continuation budget for its complete Action
and Flow chain. `max_continuations` defaults to `256` and accepts values from `0`
through `10_000`.

```elixir
Jido.Exec.run(MyApp.Reason, input, context,
  max_continuations: 12,
  timeout: 30_000
)
```

Exec returns a structured error when the next continuation would exceed the
budget. A finite `timeout` covers the same complete chain and stops slow work.
Use both limits for a reasoning loop: one bounds the number of continuations,
and one bounds elapsed time.

`Jido.Exec.run_async/4` runs the same bounded chain. The handle represents the
complete chain, not one Action.
