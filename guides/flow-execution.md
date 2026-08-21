# Executing Jido Flows

`Jido.Exec` is the public boundary for Flow execution. It validates the Flow,
runs its dependency graph, and validates the declared result.

This guide explains the runtime controls that are available now. It also
identifies controls that need an application-owned runtime boundary.

## Run A Flow

Run a Flow module:

```elixir
{:ok, result} =
  Jido.Exec.run(
    MyApp.Flows.PrepareOrder,
    %{order_id: "order-123"},
    %{tenant_id: "tenant-1"}
  )
```

Run a canonical Flow artifact:

```elixir
flow = MyApp.Flows.PrepareOrder.flow()

{:ok, result} =
  Jido.Exec.run(
    flow,
    %{order_id: "order-123"},
    %{tenant_id: "tenant-1"}
  )
```

The fourth argument contains Flow run options:

```elixir
Jido.Exec.run(flow, input, context,
  async: true,
  max_concurrency: 4
)
```

## Execution Sequence

`Jido.Exec` uses this sequence:

1. Validate the Flow structure and each action contract.
2. Normalize and validate the Flow input.
3. Compile the dependency graph to a Runic workflow.
4. Start each node when its dependencies are satisfied.
5. Resolve the node input from Flow input, context, literals, and prior results.
6. Validate and run the node action.
7. Store the successful node result for dependent nodes.
8. Resolve the declared Flow return.
9. Validate the Flow output.

Each node receives the original Flow context. A node does not receive another
node's context or extras. Data moves between nodes through action outputs.

## Serial Execution

Flow execution is serial by default:

```elixir
{:ok, result} = Jido.Exec.run(flow, input, context)
```

Runic starts one eligible node at a time. Dependencies still control the order.
Independent nodes use the canonical graph order.

Serial execution is useful when:

- actions use a constrained shared service
- deterministic start order helps local diagnosis
- the graph has little independent work
- concurrent work gives no useful latency reduction

## Concurrent Execution

Set `async: true` to let Runic schedule independent eligible nodes
concurrently:

```elixir
{:ok, result} =
  Jido.Exec.run(flow, input, context,
    async: true
  )
```

Consider this graph:

```text
load_order -> price_order -----\
          \                     -> prepare_result
           -> reserve_stock ---/
```

`price_order` and `reserve_stock` become eligible after `load_order`
completes. They can run at the same time. `prepare_result` waits for both.

`async: true` does not make every node concurrent. It changes only the
scheduling of nodes whose dependencies are already satisfied.

## Limit Concurrency

Use `max_concurrency` to limit the number of concurrent node tasks:

```elixir
{:ok, result} =
  Jido.Exec.run(flow, input, context,
    async: true,
    max_concurrency: 4
  )
```

The value must be a positive integer. When it is not supplied, the asynchronous
runner uses the number of online Erlang schedulers.

Choose the limit from the capacity of the systems that actions call. CPU count
is not always the correct service limit. A database pool, HTTP service, or rate
limit can require a smaller value.

`max_concurrency` does not create graph branches. It limits only work that the
dependency graph already makes eligible.

## Run Option Reference

These are the only public Flow run options:

| Option | Type | Default | Effect |
| --- | --- | --- | --- |
| `async` | Boolean | `false` | Allows concurrent execution of independent eligible nodes. |
| `max_concurrency` | Positive integer | Online scheduler count | Limits concurrent node tasks when asynchronous execution is active. |

Unknown options return a validation error:

```elixir
{:error, %Jido.Action.Error.InvalidInputError{}} =
  Jido.Exec.run(flow, input, context, timeout: 5_000)
```

Run options apply only to Flows. Direct actions and instructions reject them.

## Failure Behavior

When a node fails:

- `Jido.Exec` returns a structured Jido Action error.
- Nodes that depend on the failed node do not run.
- An independent branch can continue while the workflow settles.
- Asynchronous task completion order does not select the returned error.

When several independent nodes fail, Jido selects the error by canonical Flow
node order. This rule keeps the returned error deterministic.

Node action extras are not part of Flow execution. A Flow node keeps only the
action output or error.

## Retries

Jido Flow does not retry a node or a complete Flow.

`Jido.Action.Error.retryable?/1` classifies concrete Jido errors. It does not
perform a retry:

```elixir
case Jido.Exec.run(flow, input, context) do
  {:ok, result} ->
    {:ok, result}

  {:error, error} ->
    if Jido.Action.Error.retryable?(error) do
      MyApp.FlowRunner.schedule_retry(flow, input, context, error)
    else
      {:error, error}
    end
end
```

The application-owned runner must define:

- the maximum attempt count
- backoff and jitter
- which errors are retryable
- idempotency rules
- retry telemetry
- the final failure destination

A retry of `Jido.Exec.run/4` starts the complete Flow again. Jido Flow does not
persist successful node checkpoints. A complete retry can repeat actions that
already succeeded.

Do not retry non-idempotent actions unless the action and its caller share a
safe idempotency key or another duplicate-effect control.

## Timeouts

Jido Flow does not have a Flow timeout or a per-node timeout option.
`timeout:` is not a valid `Jido.Exec.run/4` option.

Put a Flow-wide timeout at the caller-owned process boundary. For example, a
supervised task can own the execution:

```elixir
def run_with_timeout(flow, input, context, timeout_ms) do
  task =
    Task.async(fn ->
      Jido.Exec.run(flow, input, context)
    end)

  case Task.yield(task, timeout_ms) ||
         Task.shutdown(task, :brutal_kill) do
    {:ok, result} ->
      result

    nil ->
      {:error,
       Jido.Action.Error.timeout_error(
         "Flow execution timed out",
         %{timeout: timeout_ms}
       )}

    {:exit, reason} ->
      {:error,
       Jido.Action.Error.execution_error(
         "Flow task exited",
         %{reason: reason}
       )}
  end
end
```

Production code must place this task under the application's supervision
strategy. It must also define what cancellation means for actions that already
started an external effect.

A killed task cannot undo an HTTP request, database write, message, or other
external effect.

## Can I Step Through A Flow?

Not through a public single-step debugger.

Jido Flow does not currently provide:

- run-next-node
- pause and resume
- breakpoints
- persisted node checkpoints
- replay from a selected node
- an interactive debugger

`Jido.Flow.compile/1` does not provide step execution. It returns an inert
Runic workflow for topology inspection. The compiled workflow does not contain
runtime input, context, or executable action work.

Use these tools instead:

1. Inspect the graph before execution.
2. attach telemetry handlers to node events.
3. Test each action directly.
4. Run the complete Flow through `Jido.Exec`.

## Inspect Before Execution

Inspect direct dependencies:

```elixir
flow = MyApp.Flows.PrepareOrder.flow()

{:ok, dependencies} = Jido.Flow.dependencies(flow)
```

Inspect the canonical graph, edges, return, and identity:

```elixir
{:ok, explanation} = Jido.Flow.explain(flow)
```

Inspect authoring metadata:

```elixir
map_with_provenance = Jido.Flow.to_map(flow, provenance: true)
```

Inspect the inert Runic topology:

```elixir
{:ok, workflow} = Jido.Flow.compile(flow)
```

These functions do not execute actions.

## Trace Each Node

Telemetry provides the closest current equivalent to stepping through a live
Flow. For local diagnosis, attach to the node span events:

```elixir
handler_id = "prepare-order-trace"

events = [
  [:jido, :flow, :node, :start],
  [:jido, :flow, :node, :stop],
  [:jido, :flow, :node, :exception]
]

:ok =
  :telemetry.attach_many(
    handler_id,
    events,
    fn event, measurements, metadata, _config ->
      IO.inspect(
        %{event: event, measurements: measurements, metadata: metadata},
        label: "Flow node"
      )
    end,
    nil
  )

try do
  Jido.Exec.run(flow, input, context,
    async: true,
    max_concurrency: 4
  )
after
  :telemetry.detach(handler_id)
end
```

Node metadata identifies the Flow, node, and action. Stop metadata includes the
status. A stop event for an error also includes the error type.

With asynchronous execution, events come from task processes and their order
can vary. Use the Flow and node metadata to correlate them.

The anonymous handler is convenient for local diagnosis. Use a named module
function for a production telemetry handler.

Do not log complete node input or output by default. It can contain secrets or
personal data.

## Runtime Capability Summary

| Capability | Available | Boundary |
| --- | --- | --- |
| Serial Flow execution | Yes | `Jido.Exec.run/3` |
| Concurrent independent nodes | Yes | `async: true` |
| Concurrency limit | Yes | `max_concurrency` |
| Graph inspection | Yes | `dependencies/1`, `explain/1`, and `compile/1` |
| Per-node telemetry | Yes | `[:jido, :flow, :node, ...]` events |
| Automatic retries | No | Application-owned runner |
| Flow timeout | No | Caller-owned process boundary |
| Per-node timeout | No | Application or action adapter boundary |
| Pause and resume | No | Not in the public runtime |
| Persisted checkpoints | No | Application-owned runtime |
| Interactive step debugger | No | Use inspection, telemetry, and action tests |

For language primitives and dependency rules, see
[Jido Flow Language](flow-language.html).
