# Execution

`Jido.Exec` is the public execution boundary for an Action, an Instruction, or
a Flow. It applies the shared validation and error rules, then returns a
normalized result.

## Run An Executable

Use `run/4` for run-to-completion execution:

```elixir
Jido.Exec.run(executable, input \\ %{}, context \\ %{}, opts \\ [])
```

The executable can be an Action module, an `%Jido.Instruction{}`, a
`%Jido.Flow{}`, or a module that uses `Jido.Flow`.

For Actions and Instructions, `opts` must be an empty list. Flow execution
supports `async: true | false` and `max_concurrency: positive_integer()`.
These options schedule independent public nodes and internal Map item calls.
One shared limit bounds their active Action calls. Reduce and Iterate work
stays serial.

## Validation Pipeline

For a leaf Action, `Jido.Exec`:

1. normalizes input and context to maps,
2. validates the Action contract,
3. calls `validate_params/1`,
4. calls `run/2`,
5. normalizes the callback return shape, and
6. calls `validate_output/1` for a normal successful result.

For an Instruction, it first merges stored parameters and context with the
call-site maps. For a Flow, it validates the Flow, checks Action contracts,
validates Flow input, executes nodes, assembles the declared output expression,
and validates Flow output.

An explicit `Jido.Action.Output` envelope is preserved as an envelope. It is
used for raw, stream, batch, and opaque successful values.

## Results, Errors, And Extras

Successful execution returns one of:

```elixir
{:ok, result}
{:ok, result, extras}
```

Direct Action and Instruction execution preserves `extras` from `run/2`. Flow
nodes use only the output or error reason and discard node extras.

Action errors, raised exceptions, thrown values, unsupported callback results,
and validator failures become structured `Jido.Action.Error` exceptions. The
main public types are:

- `Jido.Action.Error.InvalidInputError` for input or output validation,
- `Jido.Action.Error.ExecutionFailureError` for callback and execution
  failures,
- `Jido.Action.Error.ConfigurationError` for invalid executable configuration,
- `Jido.Action.Error.TimeoutError` for a timeout reported by a caller or
  adapter, and
- `Jido.Action.Error.InternalError` for unexpected internal failures.

Use `Jido.Action.Error.to_map/1` when an error crosses a process, log, or API
boundary. Error maps contain a stable `:type`, message, details, and a
conservative `:retryable?` value.

A caught Action exception, throw, or exit keeps its original stacktrace in the
runtime error's `%Splode.Stacktrace{}` field. `Jido.Action.Error.to_map/1` and
JSON encoding do not include this stacktrace.

Direct Action execution preserves an exception returned in `{:error,
exception}`. When a Flow must add node, phase, or item ownership to a foreign
exception that has no `details` field, it creates an `ExecutionFailureError`.
The wrapper keeps the foreign exception module in `details.exception`. Jido
does not add undeclared keys to the foreign exception struct.

## Telemetry

Jido emits 18 events. Nine events describe the top-level lifecycles:

- `[:jido, :action, :start]`, `[:jido, :action, :stop]`, and
  `[:jido, :action, :error]` for direct Actions and Instructions;
- `[:jido, :flow, :start]`, `[:jido, :flow, :stop]`, and
  `[:jido, :flow, :error]`; and
- `[:jido, :flow, :node, :start]`, `[:jido, :flow, :node, :stop]`, and
  `[:jido, :flow, :node, :error]`.

Nine events describe Action work inside collection nodes:

- `[:jido, :flow, :map, :item, :start]`, `:stop`, and `:error`;
- `[:jido, :flow, :reduce, :item, :start]`, `:stop`, and `:error`; and
- `[:jido, :flow, :iterate, :iteration, :start]`, `:stop`, and `:error`.

Start measurements are `%{system_time: integer, monotonic_time: integer}`.
Stop and error measurements are `%{duration: integer, monotonic_time: integer}`.

Action metadata is `%{execution_id: binary, kind: :action | :instruction,
name: term}`. Flow metadata is `%{execution_id: binary, flow: binary}`. Node
metadata is `%{execution_id: binary, flow: binary, node: binary, kind: :step |
:choice | :map | :reduce | :iterate}`. Error events add `:error` and
`:error_type`.

Map and Reduce work units add `target`, `item_index`, and `item_id`. Their
`kind` values are `:map_item` and `:reduce_item`. Iterate work units add
`target`, `iteration_index`, `iteration_id`, and `state_revision`. Their
`kind` is `:iterate_iteration`. All work units also include `execution_id`,
`flow`, and `node`.

The same `execution_id` correlates a Flow, its nodes, and nested Flows. Serial
Flow events nest as Flow and then node. Step-wise execution opens one Flow event
in `start/4` and closes it only when a step, wave, or continue operation reaches
a terminal result. An Action inside a Flow is represented by its node span and
does not emit a separate Action lifecycle. An Instruction that targets a Flow
has the Flow lifecycle inside its Action lifecycle. Async node spans can
overlap. Each async worker starts and finishes its span around the actual node
work. Start and stop events can follow scheduler and completion order. Use the
node metadata and `execution_id` for correlation instead of event position. A
killed node task still has one node error event. Collection work-unit events
can have high volume. Attach a handler only when you need this detail.

There are no scheduler, State transition, completion, or exhaustion point
events. A collection work-unit error event reports a failed Action call.
Telemetry does not control scheduling or results.

## Run A Flow Step By Step

Only Flows support the step-wise API. Start a paused execution:

```elixir
{:ok, execution} = Jido.Exec.start(flow, input, context)
```

Inspect and advance the latest execution value:

```elixir
Jido.Exec.status(execution)
Jido.Exec.ready(execution)

{:ok, node_result, execution} = Jido.Exec.step(execution)
{:ok, results, execution} = Jido.Exec.wave(execution)
{:ok, execution} = Jido.Exec.continue(execution)
{:ok, final_result} = Jido.Exec.result(execution)
```

`step/1` executes the first ready node. `step/2` executes one named ready
node. `wave/1` executes the current ready set; stored Flow concurrency options
apply to the wave. Nodes that become ready wait for the next operation.

Map, Reduce, Iterate, Choice, and nested Flow work is atomic at this public
boundary. One step completes the selected element's internal work. The API
does not expose individual Map items, Reduce items, or Iterate iterations as
ready nodes.

A failed node is an applied transition. The step operation returns
`{:ok, %Jido.Exec.NodeResult{status: :error}, execution}` and the updated
execution records the failure. Selection errors and invalid execution state
return `{:error, exception}` instead.

Always pass the newest execution to the next operation. Execution values are
caller-owned, in-memory state, not durable checkpoints or interchange maps.
Each execution stores its own `async` and `max_concurrency` settings. Reusing
an older value can run an Action and its external side effects again.

## Runtime Policy Boundary

The current public Flow execution options are `async` and
`max_concurrency`. Retry, timeout, deadline, cancellation, persistence, and
rewind are not public Flow execution options. Put those policies in a caller or
runtime layer that owns the required lifecycle. Jido does not provide queues,
recovery, supervision, distributed coordination, or deployment-safe
continuation.

## Direct Calls And Crash Isolation

Calling an Action's `run/2` directly does not add validation, supervision,
crash isolation, retries, or timeouts. Use `Jido.Exec` when you need the public
validation and error boundary.
