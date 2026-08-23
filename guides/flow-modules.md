# Author Flows With Modules

Use `Jido.Flow` to author a Flow in Elixir and validate it when the module
compiles. The module DSL lowers to the same canonical `%Jido.Flow{}` that the
[`Jido.Flow.Builder`](flow-builder.md) and stored JSON format use.

## Define A Flow Module

The module options define Flow metadata and static input and output schemas.
The `flow do` block declares the graph.

```elixir
defmodule MyApp.Flows.DoubleAfterIncrement do
  use Jido.Flow,
    name: "double_after_increment",
    description: "Adds one, then doubles the result",
    schema: Zoi.object(%{value: Zoi.integer()}),
    output_schema: Zoi.object(%{value: Zoi.integer()})

  alias MyApp.Actions.{Add, Multiply}

  flow do
    step "add_one",
      action: Add,
      params: %{value: input(:value), amount: 1}

    step "double",
      action: Multiply,
      params: %{value: select(result("add_one"), :value), amount: 2}
  end
end
```

The last outer node is the Flow output when `output` is absent. The example
therefore returns `result("double")`.

The DSL accepts these public node forms:

- `step` calls one Action or nested Flow.
- `choice` selects one Action or nested Flow.
- `map` calls one target for each collection item.
- `reduce` folds a collection through one target.
- `iterate` performs bounded State transitions.

References and `after:` fields define dependencies. Source order does not add
a dependency. Independent nodes can run in parallel when execution uses
`async: true`.

## Use Short And Block Forms

Flat declarations have equal short and block forms. Use the form that is most
clear for the amount of data in the node.

```elixir
flow do
  step "load",
    action: MyApp.Actions.Load,
    params: %{id: input(:id)}

  step "save" do
    action(MyApp.Actions.Save)
    params(%{record: result("load")})
  end
end
```

Do not mix keyword fields and a `do` block in one declaration.

## Declare An Explicit Output

Use `output` when the Flow must shape data from more than one node or include
Flow input and context.

```elixir
flow do
  step "load",
    action: MyApp.Actions.Load,
    params: %{id: input(:id)}

  step "audit",
    action: MyApp.Actions.Audit,
    params: %{record: result("load")}

  output %{
    record: result("load"),
    audit: result("audit"),
    request_id: context(:request_id)
  }
end
```

`output` must be the final declaration. A Flow must contain at least one node,
and the output expression must contain at least one node result reference.

## Static Metadata And Schemas

`name` is required. `description` is optional. `schema` validates the Flow
input. `output_schema` validates the resolved Flow output. These values must be
static module data.

The module exposes Action-compatible validation callbacks:

```elixir
MyApp.Flows.DoubleAfterIncrement.name()
MyApp.Flows.DoubleAfterIncrement.description()
MyApp.Flows.DoubleAfterIncrement.schema()
MyApp.Flows.DoubleAfterIncrement.output_schema()
MyApp.Flows.DoubleAfterIncrement.validate_params(%{value: 3})
MyApp.Flows.DoubleAfterIncrement.validate_output(%{value: 8})
```

See [Schemas And Validation](schemas-validation.md) for details.

## Compile-Time Lowering And Validation

Before the module compiles, Jido:

1. Validates module options and schemas.
2. Collects the Flow declarations.
3. Converts closed expressions and declarative conditions into Flow data.
4. Checks names, dependencies, output, and Action contracts.
5. Embeds the canonical `%Jido.Flow{}` in the module.

An invalid declaration raises a `CompileError`. The expression grammar does
not accept assignments, pattern matching, pipes, or application function
calls. Runtime input, context, and Action work stay in [Flow
execution](flow-execution.livemd).

## Generated Public Helpers

`use Jido.Flow` generates these helpers:

- `flow/0` returns the canonical `%Jido.Flow{}`.
- `to_map/1` returns a deterministic map.
- `to_stored_map/1` accepts a Registry and returns a versioned stored map.
- `to_stored_map/2` also accepts storage options.
- `validate/0` validates canonical Flow structure.
- `validate_executable/0` also checks Action and nested-Flow targets.
- `dependencies/0` returns direct predecessors.
- `explain/0` returns versioned inspection data.
- `semantic_identity/0` returns the deterministic Flow identity.
- `run/2` executes the Flow with input and context.

The generated `run/2` does not accept execution options. Use `flow/0` and
`Jido.Exec.run/4` for options:

```elixir
{:ok, result} =
  Jido.Exec.run(
    MyApp.Flows.DoubleAfterIncrement.flow(),
    %{value: 3},
    %{},
    async: true,
    max_concurrency: 2
  )
```

## Add Node Metadata

Use `meta:` for non-semantic data that tools can show. Metadata does not change
execution, dependencies, or semantic identity.

```elixir
flow do
  step "load",
    action: MyApp.Actions.Load,
    params: %{id: input(:id)},
    meta: %{label: "Load record", tags: ["read", "database"]}
end
```

Use `Jido.Flow.to_map(flow, provenance: true)` to include this data. See
[Flow inspection](flow-inspection.md) and [Stored Flow JSON](flow-storage.md).
