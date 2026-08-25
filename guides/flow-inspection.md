# Inspecting Flows

Every authoring route produces one canonical `%Jido.Flow{}`. Use the public
inspection functions to examine its meaning without depending on source form.

## Inspect dependencies

`Jido.Flow.dependencies/1` keeps explicit and inferred order separate:

```elixir
flow = MyApp.Flows.Report.flow()
{:ok, dependencies} = Jido.Flow.dependencies(flow)

%{
  after: ["authorize"],
  references: ["load"],
  effective: ["authorize", "load"]
} = dependencies["format"]
```

`after` is author control order. `references` contains dependencies inferred
from result references. `effective` is their unique union. Source order does
not create a dependency.

## Explain a Flow

`Jido.Flow.explain/1` returns versioned public inspection data:

```elixir
{:ok, explanation} = Jido.Flow.explain(flow)

1 = explanation.version
:flow = explanation.kind
["load", "format"] = Enum.map(explanation.components, & &1.name)
```

The explanation contains canonical components, dependencies, the output
expression, and semantic identity. It does not contain the Runic runtime.

## Compare semantic identity

```elixir
{:ok, identity} = Jido.Flow.semantic_identity(flow)
is_binary(identity.digest)
is_binary(identity.uuid)
```

Semantic identity excludes Spark source location and author declaration order.
Explicit component `meta` is portable author data, but it does not change the
execution graph.

## Get a semantic map

`Jido.Flow.to_map/1` returns canonical inspection data with trusted modules and
schemas as Elixir terms:

```elixir
semantic = Jido.Flow.to_map(flow)
```

Use `Jido.Flow.Codec` for database or JSON storage:

```elixir
{:ok, document} = Jido.Flow.Codec.encode(flow, registry)
{:ok, restored} = Jido.Flow.Codec.decode(document, registry)

restored == flow
```

The Registry must contain each Action, Subflow, schema, and user-data atom in
the Flow.

## Validate a Flow

`Jido.Flow.validate/1` checks canonical structure, schemas, expressions,
references, explicit order, inferred dependencies, and cycles. It does not
load or check executable targets.

`Jido.Flow.validate_executable/1` also resolves every target. Step, Choice,
Map, Reduce, and Iterate target slots require exact executable kind `:action`.
Subflow requires exact kind `:flow` and validates the child Flow recursively.

Use `Jido.Exec.run/4` for execution. Native Runic compilation and the complete
execution migration are phase-two work.
