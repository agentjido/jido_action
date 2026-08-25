# Author Flows With Modules

Use `Jido.Flow` for compile-time Flow authoring. The public Spark DSL shape is
unchanged. Its one-way lowerer creates the same canonical `%Jido.Flow{}` as the
Builder, Codec, and direct constructors.

## Define a Flow module

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

    output result("double")
  end
end
```

Every Flow requires one final output expression. Result references and
`after:` fields create dependencies. Source order does not add a dependency.

## Public forms

- `step` calls one Action or derives one Subflow.
- `choice` selects one Action option or its Action fallback.
- `map` calls one Action for each collection item.
- `reduce` folds a collection through one Action.
- `iterate` runs one Action in a bounded local State loop.
- `output` declares the required Flow result.

When a `step action:` module has executable kind `:flow`, the lowerer creates
`Jido.Flow.Subflow`. A Flow module is invalid in Choice, Map, Reduce, or
Iterate. This rule keeps Subflow equal to one independent Flow boundary.

Short and block forms remain valid. Do not mix keyword fields and a `do` block
in one declaration.

## Metadata and source data

Use `meta:` for portable author metadata:

```elixir
step "load",
  action: MyApp.Actions.Load,
  params: %{id: input(:id)},
  meta: %{label: "Load record", tags: ["read", "database"]}
```

Spark keeps file, line, and column information in a separate source map. It
does not add source data to component `meta` or the canonical Flow.

## Compile-time validation

Before the module compiles, Jido:

1. Validates Flow options and static schemas.
2. Converts quoted expressions and conditions to canonical data.
3. Constructs canonical component structs directly.
4. Derives Step or Subflow through `Jido.Executable`.
5. Checks structure, targets, references, dependencies, cycles, and output.
6. Embeds the canonical Flow and separate source map in the module.

Invalid data raises a `CompileError` at its Spark source location. Flow
expressions do not accept assignments, pattern matching, pipes, or application
function calls. Put computation in an Action.

## Generated helpers

`use Jido.Flow` generates:

- `flow/0`
- `to_map/0`
- `validate/0`
- `validate_executable/0`
- `dependencies/0`
- `explain/0`
- `semantic_identity/0`
- Action-compatible schema, validation, and `run/2` callbacks

Use the shared Codec for storage:

```elixir
{:ok, document} =
  MyApp.Flows.DoubleAfterIncrement.flow()
  |> Jido.Flow.Codec.encode(registry)
```

Use `flow/0` and `Jido.Exec.run/4` when execution options are required.
