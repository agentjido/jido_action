# Debug Flows

Debug a Flow at the narrowest boundary that can explain the problem. Start
with canonical author data. Then inspect native Runic compilation. Use a
paused execution only when the problem depends on runtime state.

## Validate Before Execution

For a module Flow, get the same canonical value that execution uses:

```elixir
flow = MyApp.OrderFlow.flow()

{:ok, flow} = Jido.Flow.validate(flow)
{:ok, flow} = Jido.Flow.validate_executable(flow)
```

`validate/1` checks Flow data, expressions, references, dependencies, and
cycles. It does not load or check Action targets. `validate_executable/1`
also checks each Action and child Flow contract. Neither function runs Action
work.

The module DSL reports an invalid definition as an Elixir compile error. The
error uses the applicable DSL file and line when source data is available.

## Inspect Author Intent

Use `explain/1` to inspect the canonical Flow without Runic support nodes:

```elixir
{:ok, explanation} = Jido.Flow.explain(flow)

explanation.components
explanation.dependencies
explanation.output
explanation.identity
```

Use `dependencies/1` when only graph order is relevant:

```elixir
{:ok, dependencies} = Jido.Flow.dependencies(flow)

dependencies["publish"]
#=> %{
#=>   after: ["approve"],
#=>   references: ["render"],
#=>   effective: ["approve", "render"]
#=> }
```

`after` is explicit author order. `references` is derived data order.
`effective` is the sorted union. This separation helps identify an unexpected
dependency without changing author intent.

## Inspect Native Runic Compilation

A compiled Flow is the primary escape hatch to Runic:

```elixir
compiled = MyApp.OrderFlow.compiled()

compiled.workflow
compiled.component_index
compiled.source_map
compiled.compilation_digest
```

For a direct or Builder Flow, use `Jido.Flow.compile/2`:

```elixir
{:ok, compiled} = Jido.Flow.compile(flow)
```

`compiled.workflow` is a native `Runic.Workflow`. Use Runic inspection tools
directly:

```elixir
Runic.Workflow.components(compiled.workflow)
Runic.Workflow.to_mermaid(compiled.workflow, direction: :LR)
Runic.Workflow.to_dot(compiled.workflow)
Runic.Workflow.to_cytoscape(compiled.workflow)
```

The native graph includes support nodes such as Join, InputBinding, FanOut,
and FanIn. These nodes are part of the execution model. Jido does not create a
second graph that hides them.

`component_index` connects an authored component name to its native component
and output:

```elixir
compiled.component_index["charge"]
```

For a module DSL Flow, `source_map` connects author paths to file, line, and
column data:

```elixir
compiled.source_map[[:components, "charge"]]
#=> %{file: "lib/my_app/order_flow.ex", line: 24, column: 5}
```

Direct construction, Builder, and stored JSON do not have source locations by
default. A caller can pass a source map to `Jido.Flow.compile/2` when its own
authoring tool has source data.

## Pause Before The First Runnable

Start a caller-owned in-memory execution:

```elixir
{:ok, execution} =
  Jido.Exec.start(MyApp.OrderFlow, input, context)

:running = Jido.Exec.status(execution)
ready = Jido.Exec.ready(execution)

workflow = Jido.Exec.workflow(execution)
compiled = Jido.Exec.compiled(execution)
```

`ready` contains native `Runic.Workflow.Runnable` values. Inspect the runnable
ID, node, input fact, and status:

```elixir
Enum.map(ready, fn runnable ->
  %{
    id: runnable.id,
    node: Map.get(runnable.node, :name),
    input_fact: runnable.input_fact,
    status: runnable.status
  }
end)
```

Input facts can contain application data. Do not copy them to logs without a
data review.

## Step, Wave, Or Continue

The three operations have different stopping points:

| Function | Work done | Stopping point |
| --- | --- | --- |
| `Jido.Exec.step/1` or `step/2` | One ready native runnable | After that runnable is applied |
| `Jido.Exec.wave/1` | The complete ready set captured at call start | Before newly ready work starts |
| `Jido.Exec.continue/1` | Repeated waves | When the Flow succeeds or fails |

A wave is one execution frontier. It is not "run until exhausted." This
boundary is useful when two independent Steps are ready at the same time. A
developer can run both, inspect the new graph state, and stop before the next
dependency level starts.

Run one selected runnable:

```elixir
[runnable | _] = ready

{:ok, applied, execution} =
  Jido.Exec.step(execution, runnable.id)

%{
  status: applied.status,
  result: applied.result,
  error: applied.error
}
```

Or run the current frontier:

```elixir
{:ok, applied, execution} = Jido.Exec.wave(execution)
```

Run all remaining work and read the terminal result:

```elixir
{:ok, execution} = Jido.Exec.continue(execution)
{:ok, result} = Jido.Exec.result(execution)
```

Always use the latest returned Execution value. Each successful `step/2` or
`wave/1` call consumes one revision. Jido rejects reuse of an old value before
it starts more Action work.

## Understand Debug Granularity

Native Runic semantics define the available stopping points:

- Step normally runs as one authored work unit.
- Choice selects and runs its target in one authored work unit.
- Iterate runs its loop in one authored runnable. Iteration telemetry provides
  the detailed view.
- Map exposes FanOut, item, FanIn, and output work.
- Reduce runs as one serial and resumable authored work unit.
- Dynamic expands the live graph when its expander returns a continuation.
- Subflow exposes its nested Workflow and InputBinding work.

Do not assume that each ready runnable is one authored Flow component.

## Read Failures

Jido returns exception structs:

```elixir
{:error, error} = Jido.Exec.run(MyApp.OrderFlow, input)

Exception.message(error)
Jido.Flow.Error.to_map(error)
```

Error details can identify a phase, component, target, choice option, item,
iteration, or runnable ID. An Action failure inside a Flow keeps its
`Jido.Action.Error` type when possible. `Jido.Flow.Error.to_map/1` also
normalizes an Action error.

A step can apply a failed runnable successfully:

```elixir
{:ok, failed_runnable, execution} = Jido.Exec.step(execution)
:failed = failed_runnable.status
{:error, error} = Jido.Exec.result(execution)
```

The first tuple means that Jido applied the Runic state transition. It does
not mean that the Action work succeeded.

## Correlate Telemetry

Jido emits start, stop, and error events for these prefixes:

```text
[:jido, :flow]
[:jido, :flow, :node]
[:jido, :flow, :target]
[:jido, :flow, :map, :item]
[:jido, :flow, :reduce, :item]
[:jido, :flow, :iterate, :iteration]
```

All nested events use one `execution_id`. Node events identify the authored
component. Target events identify a Step or selected Choice Action. Collection
and iteration events include the applicable item or iteration fields.

Collection telemetry can have high volume. Filter it by Flow, node, and
execution ID before it enters a production trace system.

## Validate Browser-authored JSON

Decode external JSON through a trusted Registry:

```elixir
with {:ok, document} <- Jason.decode(json),
     {:ok, flow} <- Jido.Flow.Codec.decode(document, registry),
     {:ok, flow} <- Jido.Flow.validate_executable(flow) do
  {:ok, flow}
end
```

`decode/2` returns the first error. Use `diagnose/2` to collect ordered,
path-based document and graph errors:

```elixir
case Jido.Flow.Codec.diagnose(document, registry) do
  {:ok, flow} -> {:ok, flow}
  {:error, errors} -> {:error, Jido.Flow.Error.to_map(errors)}
end
```

Diagnostics never return a partial Flow. Unknown-reference errors suppress a
derived cycle error. Document resource-limit and version errors are terminal.
The diagnostic operation does not check executable target contracts. Call
`Jido.Flow.validate_executable/1` after a valid result when that check is also
required.

## Runic Ownership Boundary

`Jido.Flow.Compiled.workflow` is the supported native compilation value.
`Jido.Exec.workflow/1` returns the live prepared native workflow.
`Jido.Exec.compiled/1` returns the related component index and source map.
`Jido.Exec.ready/1` returns the supported native runnable view. Jido still owns
validation, Action dispatch, execution revisions, telemetry, and final Flow
output validation.

The compiled workflow is native Runic data, but its Action work expects the
Jido runtime context that Exec installs. It is not a standalone Runic program.
A caller that takes full Runic ownership must also own Action dispatch, runtime
context, result extraction, and the other Jido execution contracts.

Other `Jido.Exec.Execution` fields are internal. Direct field access is not a
stable API. A workflow changed outside Exec cannot be applied back to the
Execution through this API. If a caller continues with Runic directly, that
caller owns the new workflow state and the missing Jido execution contracts.

See [Inspect Flows](flow-inspection.md), [Execution Contract](execution.md),
and [Security](security.md) for the related public boundaries.
