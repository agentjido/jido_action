# Inspect Flows

Flow inspection works on canonical `%Jido.Flow{}` values. It does not run
Actions.

## Validate Structure Or Targets

```elixir
{:ok, flow} = Jido.Flow.validate(flow)
{:ok, flow} = Jido.Flow.validate_executable(flow)
```

`validate/1` checks schemas, components, expressions, references, dependencies,
and cycles. It is inert and does not check module contracts.

`validate_executable/1` also checks each Action and child Flow contract. It
still does not execute work.

## Read Dependencies

```elixir
{:ok, dependencies} = Jido.Flow.dependencies(flow)

dependencies["publish"]
#=> %{
#=>   after: ["approve"],
#=>   references: ["render"],
#=>   effective: ["approve", "render"]
#=> }
```

`after` is explicit author order. `references` is derived from result
references. `effective` is their sorted union.

## Explain A Flow

```elixir
{:ok, explanation} = Jido.Flow.explain(flow)
```

The explanation is versioned canonical inspection data. It contains Flow
metadata, normalized components, dependencies, output, and semantic identity.
It is useful for tooling and review. It is not the stored JSON format.

## Compare Semantic Identity

```elixir
{:ok, identity} = Jido.Flow.semantic_identity(flow)

identity.digest
identity.uuid
```

Identity uses the canonical semantic form. Runtime compilation data and DSL
source locations do not change it.

## Get A Semantic Map

```elixir
semantic_map = Jido.Flow.to_map(flow)
```

This deterministic map keeps component declaration order and module values. It
is useful for inspection and comparison inside the VM. Use `Jido.Flow.Codec`
for portable storage.

## Inspect Native Compilation

```elixir
{:ok, compiled} = Jido.Flow.compile(flow)

compiled.workflow
compiled.component_index
compiled.output
compiled.source_map
compiled.compilation_digest
```

`Jido.Flow.Compiled` is derived runtime data. Treat its fields and native
Runic graph as inspection and execution data, not authoring data.

## Inspect Runtime Continuations

For a paused or complete step-wise execution, compare authored and live data:

```elixir
authored = Jido.Exec.compiled(execution)
live = Jido.Exec.workflow(execution)
lineage = Jido.Exec.continuations(execution)
```

The live workflow includes continuation targets that Exec added during the
run. The authored compilation does not change. Lineage is ordered and
sanitized. It does not contain continuation input, target arguments, or output
values.
