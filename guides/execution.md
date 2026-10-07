# Execution Contract

`Jido.Exec` is the public bridge from Jido definitions to Runic execution.
Every target uses the same path:

```text
Action or Flow
  -> Jido.Instruction
  -> Runic.Workflow
  -> Runic Runnable execution
```

An Action becomes a one-node workflow. A Flow becomes a workflow with real
Runic components and edges. Runic owns readiness, runnable identity,
scheduling, policy, event recording, checkpoints, persistence, and resume.

## Run To Completion

Use `run/4` for immediate in-memory execution:

```elixir
Jido.Exec.run(target, params \\ %{}, context \\ %{}, opts \\ [])
```

The target can be an Action module, Flow module, `Jido.Instruction`, or
canonical `%Jido.Flow{}`. Exec resolves the target, validates root Flow input,
compiles a Runic workflow, runs it until it stops, and projects the result.

```elixir
{:ok, result} = Jido.Exec.run(MyApp.Actions.Greet, %{name: "Ada"})

{:ok, result, effects} =
  Jido.Exec.run(MyApp.Flows.Notify, %{name: "Ada"}, %{request_id: "r-1"})
```

`run/4` uses Runic's immediate execution loop. It does not create a Jido worker,
execution struct, cursor, or checkpoint.

## Compile Without Running

Use `compile/2` when you need the native executable graph:

```elixir
{:ok, %Runic.Workflow{} = workflow} = Jido.Exec.compile(MyApp.Flows.Notify)
workflow = Jido.Exec.compile!(MyApp.Actions.Greet)
```

The compile options are:

| Option | Purpose |
| --- | --- |
| `source_map` | Add source locations to compiler errors. |
| `name` | Override the root Action node name. |
| `id` | Override the root Action node identity input. |

Flow modules supply their DSL source map automatically. Compiled workflows are
derived runtime values. Store the Flow definition as JSON and compile it after
hydration.

## Results And Errors

Successful execution returns one of these values:

```elixir
{:ok, value}
{:ok, value, effects}
```

The value is the validated Action output or Flow output. Effects are opaque
deferred requests. Exec does not dispatch them. Flow effect order follows
canonical dependency order. Collection effects follow item order.

Failed execution returns:

```elixir
{:error, exception}
```

Action validation, callback, and output failures keep their public Jido error
types. Flow coordination failures use `Jido.Flow.Error`. An Action failure is a
failed Runic Runnable. It is not a successful Fact that contains an error.

Actions can return:

```elixir
{:ok, value}
{:ok, value, effects}
{:error, reason}
{:error, reason, discarded_effects}
```

The effects list must be a proper list. Dynamic control belongs in Flow
components. Exec does not follow Action result continuations in a private loop.

## Immediate Runtime Options

`run/4` accepts these options:

| Option | Default | Rule |
| --- | --- | --- |
| `timeout` | `:infinity` | Per-attempt Runic timeout in milliseconds. |
| `max_attempts` | `1` | Total attempts, including the first attempt. |
| `backoff` | `:none` | `:none`, `:linear`, `:exponential`, or `:jitter`. |
| `base_delay_ms` | `0` | Non-negative retry delay base. |
| `max_delay_ms` | `0` | Non-negative retry delay limit. |
| `max_concurrency` | `1` | Ready Runnable concurrency for immediate execution. |

Exec converts these options to `Runic.Workflow.SchedulerPolicy`. Runic performs
the timeout, retry, backoff, and scheduling work. The default failure action is
`:halt`.

## Managed And Durable Execution

Use `start/6` with a supervised `Runic.Runner`:

```elixir
Jido.Exec.start(
  runner,
  execution_id,
  target,
  params \\ %{},
  context \\ %{},
  opts \\ []
)
```

Example:

```elixir
children = [
  {Runic.Runner, name: MyApp.Runner}
]

{:ok, _supervisor} = Supervisor.start_link(children, strategy: :one_for_one)

{:ok, _worker} =
  Jido.Exec.start(
    MyApp.Runner,
    "order-42",
    MyApp.Flows.ProcessOrder,
    %{order_id: 42},
    %{request_id: "r-42"},
    checkpoint_strategy: :every_cycle
  )
```

Managed execution checks that Instruction parameters and context contain
portable values. Its default adapter runs Action Tasks under the Runner's Task
supervisor.

Use the Runic API for lifecycle operations:

```elixir
:ok = Runic.Runner.checkpoint(MyApp.Runner, "order-42")
:ok = Runic.Runner.stop(MyApp.Runner, "order-42", persist: true)
{:ok, _worker} = Runic.Runner.resume(MyApp.Runner, "order-42")
{:ok, results} = Runic.Runner.get_results(MyApp.Runner, "order-42")
```

The configured Runic Store is the source of truth for runtime progress. A
resume restores the Runnable frontier and continues with the next work. Jido
does not encode runtime progress into Instructions or Flow JSON.

Managed execution accepts Runic worker options such as `checkpoint_strategy`,
`on_complete`, `executor`, `scheduler`, and their option lists. It also accepts
the policy options listed above, except `max_concurrency` is a worker option.

## Durable Boundaries

A durable execution has two separate records:

- the versioned Jido Flow definition, encoded with `Jido.Flow.Codec`;
- the Runic execution state, stored through `Runic.Runner.Store`.

This split lets an application hydrate the same Flow definition and restore the
exact runtime frontier. The package tests cover a ten-Action Flow that stops
after Action 5 and resumes at Action 6. They also cover recovery for Map,
Iterate, nested Flow, and Dispatch work.

A completed Action can have external effects that cannot be rolled back. Use a
stable effect identity from `Jido.Exec.effect_id/4` when a host needs deduplication.
The host still owns effect delivery and its transaction policy.

## Process And Policy Ownership

Runic owns the Worker, Scheduler, Executor, Task supervisor, and Store. Jido
provides the Action adapter and the default managed Executor. A host can replace
Runic's public scheduler, executor, or store components.

Stopping a managed execution cancels active Action Tasks. A timeout or process
exit becomes a failed Runnable and follows the selected Runic policy. Jido does
not add another Task tree or cancellation model.

## Scope

`Jido.Exec` provides Action and Flow execution. It does not provide a database,
queue, lease service, distributed coordinator, or exactly-once external effect
guarantee. Use Runic Store and Runner adapters, plus application services, for
those responsibilities.
