# Authoring Flows With Modules

Use `Jido.Flow` when you want to author a Flow in Elixir and validate it when
the module compiles. The module DSL lowers to the same canonical `%Jido.Flow{}`
artifact produced by [Flow Script](flow-script.md) and the
[`Jido.Flow.Builder`](flow-builder.md).

## Define A Flow Module

The module options define the Flow metadata and its static input and output
schemas. The `flow do` block defines the graph.

```elixir
defmodule MyApp.Flows.DoubleAfterIncrement do
  use Jido.Flow,
    name: "double_after_increment",
    description: "Adds one, then doubles the result",
    schema: Zoi.object(%{value: Zoi.integer()}),
    output_schema: Zoi.object(%{value: Zoi.integer()})

  alias MyApp.Actions.{Add, Multiply}

  flow do
    added =
      step(:add_one, Add,
        with: %{value: input(:value), amount: value(1)}
      )

    doubled =
      step(:double, Multiply,
        with: %{value: select(added, :value), amount: value(2)}
      )

    return(doubled)
  end
end
```

The DSL imports `flow/1` into the module. The expressions inside the block are
Flow data expressions. They describe input mapping and dependencies; they do
not run Actions while the module compiles. See [Flow Language](flow-language.livemd)
for the language primitives.

The block accepts these public element forms:

- `step` for one target call;
- `group` and `branch` for static authoring structure;
- `choose` for ordered routing;
- `map` and `reduce` for ordered collections; and
- `loop` for bounded work with internal State.

See [Map and Reduce](flow-collections.livemd) and [Loops and
State](flow-loops-state.livemd) for the element-specific expressions and
options.

## Static Metadata And Schemas

`name` is required. `description` is optional. `schema` validates the Flow
input and `output_schema` validates the declared return value. These options
must be static module data, so they can be stored in the compiled module.

The module exposes the same validation callbacks as an Action:

```elixir
MyApp.Flows.DoubleAfterIncrement.name()
MyApp.Flows.DoubleAfterIncrement.description()
MyApp.Flows.DoubleAfterIncrement.schema()
MyApp.Flows.DoubleAfterIncrement.output_schema()
MyApp.Flows.DoubleAfterIncrement.validate_params(%{value: 3})
MyApp.Flows.DoubleAfterIncrement.validate_output(%{value: 8})
```

For schema details, see [Schemas and Validation](schemas-validation.md).

## Compile-Time Lowering And Validation

Before the module is compiled, Jido performs these checks:

1. It validates the module options and static schemas.
2. It lowers the `flow do` operations into canonical Flow nodes and
   expressions.
3. It checks names, references, dependencies, the return expression, and the
   Action contracts.
4. It embeds the resulting `%Jido.Flow{}` value in the module.

An invalid Flow raises a `CompileError` at the Flow definition. This moves
structural errors close to the authoring code. Runtime input, context, and
Action work are still handled by [Flow execution](flow-execution.livemd).

## Generated Public Helpers

`use Jido.Flow` generates these public helpers:

- `flow/0` returns the canonical `%Jido.Flow{}`.
- `to_map/1` returns a deterministic map. Pass options such as
  `format: :stored` as the argument.
- `compile/0` returns the compiled Runic workflow for inspection.
- `dependencies/0` returns direct canonical predecessors.
- `explain/0` returns versioned inspection data.
- `semantic_identity/0` returns the deterministic Flow identity.
- `run/2` executes the Flow with input and context.

The generated `run/2` accepts only `(params, context)`. It does not accept
execution options. To use `async: true` or `max_concurrency`, obtain the Flow
with `flow/0` and call `Jido.Exec.run/4`:

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

Read [Executing Flows](flow-execution.livemd) for the run and step-wise APIs.

## Provenance Annotations

Module DSL steps can include `label`, `tags`, and `note`. Jido keeps this
information as provenance, but it does not change the semantic Flow identity
or execution dependencies. The lower-level Syntax and Builder surfaces can
also attach provenance to Choices and other operations.

```elixir
flow do
  loaded =
    step(:load, MyApp.Actions.Load,
      with: %{id: input(:id)},
      label: "Load record",
      tags: [:read, "database"],
      note: "Initial lookup"
    )

  return(loaded)
end
```

Use `Jido.Flow.to_map(flow, provenance: true)` to inspect provenance. See
[Flow inspection](flow-inspection.md).
