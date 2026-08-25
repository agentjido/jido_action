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

Action and Flow modules expose the same `Jido.Executable` contract. The
resolver selects an internal Action or Flow adapter. It does not infer a Flow
from a marker or from the presence of `flow/0`.

All targets support `jido: MyApp.Jido` for OTP instance routing. An Action
target accepts no Flow policy options. A Flow target also supports `async: true
| false` and `max_concurrency: positive_integer()`. An Instruction uses the
option rules of its resolved target. Flow policy options schedule independent
native Runic runnables and Map item calls. One shared limit bounds their active
Action calls. Reduce and Iterate Action calls stay serial inside their owning
runtime work.

The `jido:` option routes each Action worker through
`MyApp.Jido.TaskSupervisor`, which is the Task Supervisor name used by Jido
core instances. The instance must be running. A missing instance returns a
structured validation error. Exec does not silently use its global Task
Supervisor. If `:jido` is absent or `nil`, Exec uses
`Jido.Exec.TaskSupervisor`.

## Validation Pipeline

For a leaf Action, `Jido.Exec`:

1. normalizes input and context to maps,
2. validates the Action contract,
3. calls `validate_params/1`,
4. calls `run/2`,
5. normalizes the callback return shape, and
6. calls `validate_output/1` for a normal successful result.

For an Instruction, Jido first merges stored parameters and context with the
call-site maps. It then runs the Action or Flow pipeline for the resolved
target. For a Flow, it validates the Flow, checks Action contracts, validates
Flow input, executes nodes, assembles the declared output expression, and
validates Flow output.

An explicit `Jido.Action.Output` envelope is preserved as an envelope. It is
used for raw, stream, batch, and opaque successful values.

## Results, Errors, And Extras

Successful execution returns one of:

```elixir
{:ok, result}
{:ok, result, extras}
```

Direct Action execution and an Instruction with an Action target preserve
`extras` from `run/2`. Flow nodes use only the output or error reason and
discard node extras.

Action-owned failures become structured `Jido.Action.Error` exceptions. The
main public types are:

- `Jido.Action.Error.InvalidInputError` for input or output validation,
- `Jido.Action.Error.ExecutionFailureError` for callback and execution
  failures,
- `Jido.Action.Error.ConfigurationError` for invalid executable configuration,
- `Jido.Action.Error.TimeoutError` for a timeout reported by a caller or
  adapter, and
- `Jido.Action.Error.InternalError` for unexpected internal failures.

Flow definition, compilation, native execution, and execution-state failures
use `Jido.Flow.Error`:

- `Jido.Flow.Error.InvalidDefinitionError` for invalid canonical or authored
  Flow data,
- `Jido.Flow.Error.InvalidExecutionError` for invalid Flow input, options, or
  execution state,
- `Jido.Flow.Error.ExecutionFailureError` for native Flow execution failures,
  including multiple failed runnables, and
- `Jido.Flow.Error.InternalError` for an unexpected internal Flow failure.

An Action failure inside a Flow keeps its original `Jido.Action.Error` type.
The common `Jido.Executable` resolver uses
`Jido.Action.Error.ConfigurationError` when resolution fails before it knows
the executable kind. Jido does not add a third executable error model.

Use `Jido.Action.Error.to_map/1` for an Action error. Use
`Jido.Flow.Error.to_map/1` for a Flow error. `Jido.Flow.Error.to_map/1` also
accepts an Action error, which is useful at a Flow boundary. Error maps contain
a stable `:type`, message, details, and a conservative `:retryable?` value.

An `ExecutionFailureError` returned by an Action is retryable by default for
compatibility with Jido Action v2. The Action can set `details.retry` to a
Boolean value. Jido sets it to `false` for callback crashes, throws, invalid
callback results, validator contract failures, and killed Action processes.
These failures need a code or contract change. A retry alone does not correct
them.

A caught Action exception, throw, or exit keeps its original stacktrace in the
runtime error's `%Splode.Stacktrace{}` field. Stable error maps and JSON
encoding do not include this stacktrace.

Direct Action execution preserves an exception returned in `{:error,
exception}`. When a Flow must add node, phase, or item ownership to a foreign
exception that has no `details` field, it creates an `ExecutionFailureError`.
The wrapper keeps the foreign exception module in `details.exception`. Jido
does not add undeclared keys to the foreign exception struct.

## Telemetry

Jido emits 21 events. Twelve events describe the top-level lifecycles:

- `[:jido, :action, :start]`, `[:jido, :action, :stop]`, and
  `[:jido, :action, :error]` for direct Actions and Instructions;
- `[:jido, :flow, :start]`, `[:jido, :flow, :stop]`, and
  `[:jido, :flow, :error]`; and
- `[:jido, :flow, :node, :start]`, `[:jido, :flow, :node, :stop]`, and
  `[:jido, :flow, :node, :error]`; and
- `[:jido, :flow, :target, :start]`, `[:jido, :flow, :target, :stop]`, and
  `[:jido, :flow, :target, :error]` for Step targets and the selected Choice
  target.

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

Target metadata is `%{execution_id: binary, flow: binary, node: binary, kind:
:step | :choice, target: module, option: term}`. A Step has `option: nil`. A
Choice has the selected option name. No target event occurs when Choice
condition evaluation fails before selection.

Map and Reduce work units add `target`, `item_index`, and `item_id`. Their
`kind` values are `:map_item` and `:reduce_item`. Iterate work units add
`target`, `iteration_index`, `iteration_id`, and `state_revision`. Their
`kind` is `:iterate_iteration`. All work units also include `execution_id`,
`flow`, and `node`.

The same `execution_id` correlates a Flow, its components, and child work.
Serial Flow events nest as Flow and then component. Step-wise execution opens
one Flow event in `start/4`. It closes the event only when a step, wave, or
continue operation reaches a terminal result. A Step or selected Choice Action
has a target span inside its node span. Collection Actions have work-unit
spans. Flow targets do not emit a separate direct Action lifecycle or child
Flow lifecycle. An Instruction that targets a Flow has the Flow lifecycle
inside its Action lifecycle. Async node spans can overlap. Each async worker
starts and finishes its span around the actual node work. Start and stop events
can follow scheduler and completion order. Use the node metadata and
`execution_id` for correlation instead of event position. A killed node task
still has one node error event. Collection work-unit events can have high
volume. Attach a handler only when you need this detail. Asynchronous node and
collection workers copy the caller's Logger metadata at dispatch time.

Native support runnables do not get an artificial Jido component span.

There are no scheduler, State transition, completion, or exhaustion point
events. A collection work-unit error event reports a failed Action call.
Telemetry does not control scheduling or results.

## Run A Flow Step By Step

A Flow or an Instruction with a Flow target supports the step-wise API. Start
a paused execution:

```elixir
{:ok, execution} = Jido.Exec.start(flow, input, context)
```

Inspect and advance the latest execution value:

```elixir
Jido.Exec.status(execution)
Jido.Exec.ready(execution)

{:ok, runnable, execution} = Jido.Exec.step(execution)
{:ok, runnables, execution} = Jido.Exec.wave(execution)
{:ok, execution} = Jido.Exec.continue(execution)
{:ok, final_result} = Jido.Exec.result(execution)
```

`ready/1` returns native `Runic.Workflow.Runnable` values. `step/1` executes
the first ready runnable. `step/2` selects one ready runnable by value or ID.
`wave/1` executes the current ready set. Runnables that become ready wait for
the next operation.

A failed runnable stops the Flow after Jido applies the failure. If two or more
runnables in one wave fail, `result/1` returns a
`Jido.Flow.Error.ExecutionFailureError`. Its `failures` field keeps the node,
native runnable ID, and original error for each failure.

The API exposes native Runic support work. Ready values can contain Step,
Join, InputBinding, FanOut, FanIn, collector, validator, and nested Flow work.
Jido does not create a second public-node scheduler.

A failed runnable is an applied transition. The step operation returns
`{:ok, %Runic.Workflow.Runnable{status: :failed}, execution}`. Selection
errors and invalid execution state return `{:error, exception}`.

Always pass the newest execution to the next operation. Execution values are
caller-owned, in-memory state, not durable checkpoints or interchange maps.
Each execution stores its own `async` and `max_concurrency` settings. Jido
rejects an older execution revision before it dispatches work.

## Runtime Policy Boundary

The current public Flow policy options are `async` and `max_concurrency`.
Common `jido:` routing selects an OTP instance but does not change Flow policy.
Retry, timeout, deadline, cancellation, persistence, and rewind are not public
Flow execution options. Put those policies in a caller or runtime layer that
owns the required lifecycle. Jido does not provide queues, recovery,
distributed coordination, or deployment-safe continuation.

## Direct Calls And Crash Isolation

Calling an Action's `run/2` directly does not add validation, supervision,
crash isolation, retries, or timeouts. Use `Jido.Exec` when you need the public
validation and error boundary.

`Jido.Exec` owns the global Task Supervisor and the concurrency processes that
support this boundary. With `jido: MyApp.Jido`, it uses the running Jido core
instance Task Supervisor for Action workers. The short-lived Flow concurrency
limiter stays in the Exec-global tree and uses a unique execution ID. These
processes belong to execution, not to an Action definition.
