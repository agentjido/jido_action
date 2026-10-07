# Debug Flows

Debug a Flow at three boundaries: its author data, its compiled Runic graph,
and its Runic execution events.

## Validate Author Data

```elixir
with {:ok, flow} <- Jido.Flow.new(definition),
     {:ok, flow} <- Jido.Flow.validate(flow) do
  Jido.Flow.explain(flow)
end
```

`Jido.Flow.validate/1` is inert. It reports definition, expression, reference,
dependency, and cycle errors without loading target modules.

For stored data, use the Codec diagnostic path:

```elixir
Jido.Flow.Codec.diagnose(document, registry)
```

It returns all independent document and graph errors with stored-document
paths. It does not return a partial Flow.

## Compile The Executable Graph

```elixir
case Jido.Exec.compile(MyApp.OrderFlow) do
  {:ok, workflow} -> Runic.Workflow.build_log(workflow)
  {:error, error} -> Jido.Flow.Error.to_map(error)
end
```

Compilation validates Action and child Flow targets. Flow modules supply their
DSL source maps automatically. Errors include the component path and source
location when that information is available.

For a canonical Flow value from another authoring system, pass its source map
when one exists:

```elixir
Jido.Exec.compile(flow, source_map: source_map)
```

## Inspect Immediate Failures

```elixir
case Jido.Exec.run(MyApp.OrderFlow, input, context) do
  {:ok, value} -> {:ok, value}
  {:ok, value, effects} -> {:ok, value, effects}
  {:error, error} -> {:error, Exception.message(error)}
end
```

An Action error is the error from the failed Runic Runnable. Error details can
include `node`, `node_path`, collection index, iteration state, and DSL source
location.

## Inspect Managed Execution

Start a managed execution with a stable ID:

```elixir
{:ok, _worker} =
  Jido.Exec.start(MyApp.Runner, "order-42", MyApp.OrderFlow, input, context,
    checkpoint_strategy: :every_cycle
  )
```

Use Runic operations for runtime inspection:

```elixir
Runic.Runner.get_results(MyApp.Runner, "order-42")
Runic.Runner.checkpoint(MyApp.Runner, "order-42")
Runic.Runner.stop(MyApp.Runner, "order-42", persist: true)
Runic.Runner.resume(MyApp.Runner, "order-42")
```

The Store and event stream are the runtime evidence. Jido does not have a
parallel execution value, revision token, or ready-work list.

## Inspect The Three Phases

For low-level tests or tools, use Runic's public execution phases:

```elixir
workflow = Jido.Exec.compile!(MyApp.OrderFlow)
workflow = Runic.Workflow.plan_eagerly(workflow, input)
{workflow, runnables} = Runic.Workflow.prepare_for_dispatch(workflow)
```

Execute each Runnable through its Runic component and apply the result with
`Runic.Workflow.apply_runnable/2`. This is the same contract used by schedulers.
Do not read or edit private graph state.

## Runic Ownership Boundary

`Jido.Flow` owns the declarative definition. The internal Exec compiler lowers
it to Runic. Runic owns graph readiness, runnable creation, scheduling, retries,
checkpoints, persistence, and resume. A debugging tool should inspect each
layer through its public API.
