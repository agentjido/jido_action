# Executing Flows

`Jido.Exec` is the public execution boundary for actions, instructions, and
Flows. It can run a Flow to completion or expose the Flow one ready node at a
time.

## Run To Completion

Pass a Flow module or canonical `Jido.Flow` artifact to `Jido.Exec.run/4`.

```elixir
{:ok, result} =
  Jido.Exec.run(
    MyApp.Flows.BuildReport,
    %{account_id: "acct-123"},
    %{request_id: "req-123"}
  )
```

Flow execution follows this boundary:

1. Validate the Flow and all target action contracts.
2. Normalize and validate Flow input and context.
3. Execute ready Flow nodes.
4. Resolve the declared return expression.
5. Validate the Flow output.

`Jido.Exec.run/4` uses the same engine as step-wise execution. It starts an
execution, continues all waves, and returns the cached final result.

## Run Independent Nodes In Parallel

Flows run serially by default. Use `async: true` to run independent nodes in
the same ready wave concurrently.

```elixir
{:ok, report} =
  Jido.Exec.run(MyApp.Flows.BuildReport, input, context,
    async: true,
    max_concurrency: 4
  )
```

| Option | Default | Meaning |
| --- | --- | --- |
| `async` | `false` | Runs independent nodes in a ready wave concurrently. |
| `max_concurrency` | Online scheduler count | Limits concurrent node tasks when `async` is true. |

`max_concurrency` must be a positive integer. Run options are accepted only
for Flows.

Parallel execution does not change Flow dependencies. A node waits until all
of its predecessors complete. Results and errors remain ordered by canonical
Flow node order, not task completion time.

## Start A Paused Execution

Use `Jido.Exec.start/4` to validate the Flow and pause before the first named
Flow node runs.

```elixir
{:ok, execution} =
  Jido.Exec.start(
    MyApp.Flows.BuildReport,
    %{account_id: "acct-123"},
    %{request_id: "req-123"}
  )

:running = Jido.Exec.status(execution)
["load_account", "load_orders"] = Jido.Exec.ready(execution)
```

The returned `Jido.Exec.Execution` is opaque. Jido automatically handles Runic
coordination work, such as multi-parent joins. `ready/1` exposes only named
Jido Flow nodes in canonical order.

## Execute One Node

`step/1` runs the first ready node in canonical order. `step/2` runs a selected
ready node.

```elixir
{:ok, node_result, execution} =
  Jido.Exec.step(execution, "load_account")

%Jido.Exec.NodeResult{
  node: "load_account",
  status: :ok,
  output: account,
  error: nil,
  attempt: 1
} = node_result
```

The execution pauses again after the node and after any internal coordination
work. Call `ready/1` to see the next public nodes.

```elixir
["build_summary"] = Jido.Exec.ready(execution)
```

Selecting a node that is not ready returns an `InvalidInputError`. The original
execution value is unchanged.

## Execute One Wave

`wave/1` freezes the current ready set and executes only that set. Nodes that
become ready during the wave wait for the next call.

```elixir
{:ok, execution} =
  Jido.Exec.start(MyApp.Flows.BuildReport, input, context,
    async: true,
    max_concurrency: 2
  )

{:ok, node_results, execution} = Jido.Exec.wave(execution)
```

With `async: false`, the wave runs its nodes serially. With `async: true`, the
wave can run them concurrently. In both cases, `node_results` uses canonical
Flow node order.

## Continue To Completion

Use `continue/1` to run all remaining waves. It returns the terminal execution,
not the Flow output.

```elixir
{:ok, execution} = Jido.Exec.continue(execution)
:succeeded = Jido.Exec.status(execution)
{:ok, report} = Jido.Exec.result(execution)
```

Execution status has three values:

| Status | Meaning |
| --- | --- |
| `:running` | Public Flow work remains available. |
| `:succeeded` | All work completed and the Flow output is valid. |
| `:failed` | Execution settled with a node, engine, or output error. |

`result/1` returns an error while the execution is still running. On a terminal
execution, it returns the cached Flow result. Repeated calls do not repeat
output validation.

## Handle A Node Failure

A node failure is a valid state transition. `step/1`, `step/2`, and `wave/1`
return `:ok` with a `NodeResult` that has `status: :error`.

```elixir
{:ok, node_result, execution} =
  Jido.Exec.step(execution, "load_account")

:error = node_result.status
error = node_result.error
```

Jido skips nodes that depend on the failed node. Independent nodes can remain
ready, so the execution can stay `:running` after one node fails.

```elixir
["record_audit"] = Jido.Exec.ready(execution)
{:ok, _result, execution} = Jido.Exec.step(execution, "record_audit")

:failed = Jido.Exec.status(execution)
{:error, error} = Jido.Exec.result(execution)
```

This return shape separates API misuse from a Flow transition:

- `{:ok, node_result, execution}` means Jido applied the node outcome.
- `{:error, error}` means Jido did not perform the requested transition.

## Step Through A Choice

A Choice is one public Flow node. Stepping it evaluates its conditions and runs
only the selected target.

```elixir
["shipping_route"] = Jido.Exec.ready(execution)

{:ok, choice_result, execution} =
  Jido.Exec.step(execution, "shipping_route")
```

The node result contains the selected target output. Choice options are not
separate ready nodes. See [Flow Choices](flow-choices.md) for routing semantics.

## Use Execution Values Safely

Each transition returns a new immutable execution value. Always pass the latest
value to the next operation.

```elixir
{:ok, first_result, execution} = Jido.Exec.step(execution)
{:ok, second_result, execution} = Jido.Exec.step(execution)
```

Do not reuse an older value. Reusing it can run the same action again and can
repeat external side effects.

An execution can move to another process, but it is an in-memory value. Do not
serialize it or use it as a persistent checkpoint.

## Know The Current Limits

The current Flow execution API does not provide:

- Per-node retries or retry backoff.
- Per-node timeout or Flow deadline options.
- Cancellation or rewind.
- Persistent checkpoints or restart-safe resume.
- Exactly-once guarantees for action side effects.

Nested Flows execute as one node in the parent execution. Step-wise execution
does not enter the nested Flow in this release. Parent `async` and
`max_concurrency` options do not pass to the nested Flow. A nested Flow uses
the default serial policy when it runs as a target.

Layer external runtime policy around `Jido.Exec`. Do not place retry, timeout,
or persistence policy in the Flow artifact.
