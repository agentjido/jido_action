# Debug Flows

Debug a Flow in the order that its problems can appear: the definition, the
targets, the run, and the runtime.

## 1. Check The Definition

`Jido.Flow.validate/1` checks structure, references, expressions,
dependencies, and cycles. It does not load target modules or run work.

```elixir
with {:ok, flow} <- Jido.Flow.new(definition),
     {:ok, flow} <- Jido.Flow.validate(flow) do
  Jido.Flow.dependencies(flow)
end
```

`Jido.Flow.dependencies/1` shows, for each component, its explicit `needs`,
the components it references, and the effective dependency list. Use it when
a component runs earlier or later than you expect. Source order never creates
a dependency.

For a stored document, use `Jido.Authoring.decode/2`. It returns ordered issues
with document paths:

```elixir
case Jido.Authoring.decode(document, registry: registry, codec: Jido.Flow.Codec) do
  {:ok, flow} -> {:ok, flow}
  {:error, issues} -> {:error, Enum.map(issues, &Jido.Authoring.Issue.to_map/1)}
end
```

Module Flows report definition errors at compile time, with the DSL source
location.

## 2. Check The Targets

`Jido.Exec.compile/2` loads and checks every Action and child Flow target:

```elixir
case Jido.Exec.compile(MyApp.Flows.Order) do
  {:ok, _workflow} -> :ok
  {:error, error} -> Jido.Flow.Error.to_map(error)
end
```

A Flow module includes its DSL source map, so compile errors point to the
declaration. When you compile a `%Jido.Flow{}` from another source, pass
`source_map:` if that source has one.

## 3. Read A Failed Run

```elixir
case Jido.Exec.run(MyApp.Flows.Order, input, context) do
  {:ok, value} -> {:ok, value}
  {:ok, value, effects} -> {:ok, value, effects}
  {:error, error} -> {:error, Jido.Flow.Error.to_map(error)}
end
```

An Action failure inside a Flow keeps its Action error type and adds:

- `node`: the component name;
- `node_path`: the path through nested Flows;
- `source`: the DSL file and line, for module Flows;
- `item_index` and `item_id` for Map and Reduce items; and
- `iteration_index` for Iterate.

A Flow coordination failure, such as a missing reference path or a
non-Boolean condition, is a `Jido.Flow.Error.ExecutionFailureError` with a
`reason` and `phase`. See [Errors](errors.md) for every case.

Runic logs a warning for each failed runnable. The returned error is the
authoritative result.

## 4. Narrow The Problem

- Run the failing Action alone with `Jido.Exec.run/4` and the params that the
  Flow passed.
- Call the Action's `validate_params/1` and `validate_output/1` to separate
  schema problems from callback problems.
- Set `max_concurrency: 1` (the default) to make the order of side effects
  easier to follow.
- Attach a handler to `Jido.Exec.Telemetry.event_names/0` to see each Action
  attempt with its `component`, `node_path`, and `attempt`. See
  [Execution](execution.md#telemetry).

## 5. Inspect A Managed Execution

For an execution under a `Runic.Runner`, read its state through the Runner:

```elixir
{:ok, %{result: fact}} = Runic.Runner.get_results(MyApp.Runner, "order-42", facts: true)
{:ok, workflow} = Runic.Runner.get_workflow(MyApp.Runner, "order-42")

failures =
  for %Runic.Workflow.RunnableFailed{} = event <- workflow.runnable_events, do: event
```

Use Runic operations for runtime inspection and Jido Exec to resume and read
the result:

```elixir
{:ok, workflow} = Runic.Runner.get_workflow(MyApp.Runner, "order-42")
Jido.Exec.result(MyApp.Runner, "order-42")
Runic.Runner.checkpoint(MyApp.Runner, "order-42")
Runic.Runner.stop(MyApp.Runner, "order-42", persist: true)
Jido.Exec.resume(MyApp.Runner, "order-42", context, checkpoint_strategy: :every_cycle)
```

Pass `resume/4` the same context and options as `start/6`. Runic does not
persist them.

The Store and event stream are the runtime evidence. Jido does not have a
parallel execution value, revision token, or ready-work list.

Start an execution with `dispatch_mode: :manual` and call `Jido.Exec.step/2`
to advance it one unit at a time. See
[Managed Execution](managed-execution.md#step-through-an-execution).

## Inspect Ready Work

Start managed work with `dispatch_mode: :manual` to inspect it before dispatch.
Read a snapshot through the Runner and use Runic's public preparation API:

```elixir
{:ok, workflow} = Runic.Runner.get_workflow(MyApp.Runner, "order-42")
{_snapshot, runnables} = Runic.Workflow.prepare_for_dispatch(workflow)
Enum.map(runnables, & &1.node.name)
```

This operates on a copy. It does not advance the live worker. Use
`Jido.Exec.step/2` or `Runic.Runner.continue/2` to dispatch live work. Do not
feed raw application input to a compiled Flow through `plan_eagerly/2`:
Flow input validation and the runtime frame are supplied by the Exec boundary.
Do not construct that private frame in application code.

## Runic Ownership Boundary

`Jido.Flow` owns the declarative definition. The internal Exec compiler lowers
it to Runic. Runic owns graph readiness, runnable creation, scheduling, retries,
checkpoints, persistence, and resume. A debugging tool should inspect each
layer through its public API.
