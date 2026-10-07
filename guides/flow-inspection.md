# Inspect Flows

Flow inspection separates inert author data from executable Runic data.

## Validate Structure Or Targets

Use `Jido.Flow.validate/1` for inert structural validation:

```elixir
{:ok, flow} = Jido.Flow.validate(flow)
```

This checks schemas, components, expressions, references, dependencies, and
cycles. It does not load Action targets.

Use `Jido.Exec.compile/2` to check executable targets and build the Runic graph:

```elixir
{:ok, %Runic.Workflow{} = workflow} = Jido.Exec.compile(flow)
```

Neither operation runs Action work.

## Read Dependencies

```elixir
{:ok, dependencies} = Jido.Flow.dependencies(flow)
```

Each component entry contains explicit `needs`, referenced components, and the
effective dependency list.

## Explain A Flow

```elixir
{:ok, explanation} = Jido.Flow.explain(flow)
```

The explanation contains the canonical components, dependencies, output, and
semantic identity. It contains author data and no runtime state.

## Compare Semantic Identity

```elixir
{:ok, identity} = Jido.Flow.semantic_identity(flow)
```

The identity is deterministic for the canonical Flow definition. Runtime
context, execution state, and source locations do not change it.

## Get A Semantic Map

```elixir
map = Jido.Flow.to_map(flow)
```

Use this map for inspection. Use `Jido.Flow.Codec` for database storage because
the Codec records versions and replaces modules and atoms through a safe
Registry.

## Inspect Native Compilation

`Jido.Exec.compile/2` returns the exact `Runic.Workflow` that Exec can run:

```elixir
{:ok, workflow} = Jido.Exec.compile(flow)
Runic.Workflow.build_log(workflow)
```

Use Runic's public functions to inspect components, ports, build events,
runnable events, and results. The compiled workflow is derived runtime data.
Do not use it as the canonical stored Flow definition.
