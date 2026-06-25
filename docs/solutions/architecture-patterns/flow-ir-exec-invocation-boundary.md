---
title: Keep Flow IR Separate from Exec Invocation
date: 2026-06-25
category: architecture-patterns
module: Jido.Flow / Jido.Exec
problem_type: architecture_pattern
component: tooling
severity: medium
applies_when:
  - "Adding Flow execution behavior that calls actions"
  - "Refactoring action return-shape or error normalization"
  - "Preserving Jido.Flow as an IR and action-composability layer"
related_components:
  - "Jido.Flow.Compiler"
  - "Jido.Exec"
  - "Jido.Instruction"
tags:
  - flow
  - exec
  - invocation-normalization
  - ir-boundary
  - action-composability
---

# Keep Flow IR Separate from Exec Invocation

## Context

While adding the binding-first `Jido.Flow` script spine, `Jido.Flow.Compiler`
temporarily duplicated action invocation normalization: it called `action.run/2`
directly, interpreted `{:ok, output}`, `{:ok, output, extras}`,
`{:error, reason}`, unsupported return shapes, raises, and throws, then added
Flow step metadata.

That made Flow responsible for behavior that belongs to the execution boundary.
The design decision is: `Jido.Flow` models the IR and action composability;
`Jido.Exec` is the exclusive owner of action invocation normalization.

## Guidance

Keep action invocation normalization behind `Jido.Exec`. Flow may ask Exec to
invoke an action, but Flow should only add graph-local context such as the step
name, phase, and action module.

The shared boundary is `Jido.Exec.invoke_action/3`:

```elixir
@doc false
@spec invoke_action(module(), map(), map()) ::
        {:ok, term(), term() | :none} | {:error, Exception.t()}
def invoke_action(action, params, context) do
  case action.run(params, context) do
    {:ok, output} ->
      {:ok, output, :none}

    {:ok, output, extras} ->
      {:ok, output, extras}

    {:error, reason} ->
      {:error, normalize_action_error(reason)}

    {:error, reason, _extras} ->
      {:error, normalize_action_error(reason)}

    other ->
      {:error,
       Error.execution_error("action returned an unsupported result", %{
         action: action,
         result: other
       })}
  end
rescue
  exception ->
    {:error,
     Error.execution_error(Exception.message(exception), %{
       action: action,
       exception: exception.__struct__
     })}
catch
  kind, reason ->
    {:error,
     Error.execution_error("action #{kind}", %{
       action: action,
       reason: reason
     })}
end
```

`Jido.Flow.Compiler` then delegates invocation and limits itself to Flow-specific
step handling:

```elixir
defp call_action(node, params, context) do
  node.action
  |> Exec.invoke_action(params, context)
  |> drop_action_extras()
  |> tag_step_execution_error(node)
end

defp tag_step_execution_error({:error, error}, node) when is_exception(error) do
  {:error, put_step_details(error, node)}
end

defp step_details(node) do
  %{
    phase: :step_execution,
    node: node.name,
    action: node.action
  }
end
```

This keeps `Jido.Flow.Compiler` focused on:

- resolving Flow refs and literal expressions
- validating step input and output at the graph boundary
- sequencing Runic steps
- storing node results
- extracting the declared Flow return

It keeps `Jido.Exec` focused on:

- validating action contracts
- invoking actions
- preserving action extras for leaf action execution
- normalizing action return shapes, raised exceptions, throws, and returned errors

## Why This Matters

Duplicating invocation normalization creates semantic drift. If `Jido.Exec` learns
a new accepted return shape, changes how extras are represented, or tightens
error normalization, a second implementation in Flow can silently diverge.

Keeping invocation normalization exclusive to Exec also preserves the conceptual
shape of the v4 package:

- `Jido.Instruction` is a small action call frame.
- `Jido.Flow` is the compositional IR for action graphs.
- `Jido.Exec` is the runtime boundary that knows how to execute artifacts and
  normalize action calls.

Flow still owns Flow-specific metadata. Adding `phase: :step_execution`,
`node: node.name`, and `action: node.action` is graph context, not action
invocation policy.

## When to Apply

- When adding new Flow runtime behavior that executes actions.
- When changing supported action return shapes.
- When adding error handling for action raises, throws, or returned exception
  values.
- When deciding whether a behavior belongs in Flow, Instruction, or Exec.

## Examples

Avoid this shape in Flow:

```elixir
defp call_action(node, params, context) do
  case node.action.run(params, context) do
    {:ok, output} -> {:ok, output}
    {:ok, output, _extras} -> {:ok, output}
    {:error, reason} -> {:error, normalize_action_error(node, reason)}
    other -> {:error, unsupported_result(node, other)}
  end
rescue
  exception -> {:error, step_exception(node, exception)}
catch
  kind, reason -> {:error, step_throw(node, kind, reason)}
end
```

Prefer this shape:

```elixir
defp call_action(node, params, context) do
  node.action
  |> Exec.invoke_action(params, context)
  |> drop_action_extras()
  |> tag_step_execution_error(node)
end
```

Tests should cover both sides of the boundary:

- `Jido.Exec` tests assert accepted action return tuples, extras, raised
  exceptions, throws, unsupported return shapes, and normalized error reasons.
- `Jido.Flow.Compiler` tests assert that Flow preserves the normalized errors
  and adds step metadata where the error type supports details.
- Flow tests should not duplicate every action invocation normalization case
  unless the Flow-specific wrapping behavior is involved.

## Related

- `lib/jido_exec.ex`
- `lib/jido_flow/compiler.ex`
- `test/jido_exec/exec_test.exs`
- `test/jido_flow/compiler_test.exs`
