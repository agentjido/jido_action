# Jido Action

`jido_action` defines validated actions, action call frames, data-first Flows,
and one public execution boundary.

Jido Flow is a declarative, in-memory graph execution layer for Jido Actions.
Runic owns graph mechanics, planning, runnable discovery, node execution, and
graph-state transitions. Jido Flow owns its DSL, validation, lossless Map/JSON
representation, compilation, and Flow semantics. Jido Exec owns one in-memory
execution session: step-wise execution, bounded concurrency, Action invocation,
errors, telemetry, and final results.

Durable orchestration is not provided. An outer system must own persistence,
queues, scheduling, recovery, retries, cancellation, deadlines, distributed
coordination, supervision, and deployment-safe continuation.

This foundation keeps the action boundary small:

- `Jido.Action` defines a named action with Zoi input and output schemas.
- `Jido.Instruction` captures one requested action call as data.
- `Jido.Flow` composes actions as a validated graph with steps and Choices.
- `Jido.Exec` runs actions, instructions, and Flows, including step-wise Flows.

Version 3.0.0-rc.1 is a release candidate. It introduces the declarative Flow
DSL, runtime Flow construction, safe stored Flow maps, and one Flow execution
engine. Test it before you use it in production. See the [v3 migration
guide](guides/v3-migration.md) for the confirmed breaking changes.

## Install

```elixir
def deps do
  [
    {:jido_action, "~> 3.0.0-rc.1"}
  ]
end
```

## Define An Action

```elixir
defmodule MyApp.Actions.GreetUser do
  use Jido.Action,
    name: "greet_user",
    description: "Builds a greeting for a user",
    schema:
      Zoi.object(%{
        name: Zoi.string() |> Zoi.min(1),
        excited?: Zoi.boolean() |> Zoi.default(false)
      }),
    output_schema:
      Zoi.object(%{
        greeting: Zoi.string()
      })

  @impl true
  def run(%{name: name, excited?: excited?}, _context) do
    suffix = if excited?, do: "!", else: "."
    {:ok, %{greeting: "Hello, #{name}#{suffix}"}}
  end
end
```

Public action functions:

- `name/0`
- `description/0`
- `schema/0`
- `output_schema/0`
- `validate_params/1`
- `validate_output/1`
- `run/2`

## Validate And Run An Action

```elixir
{:ok, params} = MyApp.Actions.GreetUser.validate_params(%{name: "Ada", excited?: true})
{:ok, result} = MyApp.Actions.GreetUser.run(params, %{request_id: "req-123"})
{:ok, result} = MyApp.Actions.GreetUser.validate_output(result)
```

`run/2` must return one of:

- `{:ok, result}`
- `{:ok, result, extra}`
- `{:error, reason}`
- `{:error, reason, extra}`

Three-tuple returns let callers receive an extra value alongside the result or error.

## Capture A Call Frame

Use `Jido.Instruction` when the intent to run an action needs to be passed,
logged, queued, or enriched before execution.

```elixir
instruction =
  Jido.Instruction.new!(
    action: MyApp.Actions.GreetUser,
    params: %{name: "Ada"},
    context: %{request_id: "req-123"}
  )
```

An instruction is one action call frame. It is not a workflow, program, or runtime.

## Compose A Flow

Use `Jido.Flow` when several actions must execute as one validated graph.

```elixir
defmodule MyApp.Actions.Notify do
  use Jido.Action,
    name: "notify",
    schema: Zoi.object(%{message: Zoi.string()})

  @impl true
  def run(%{message: message}, _context) do
    {:ok, %{message: message, status: "queued"}}
  end
end

defmodule MyApp.Flows.GreetAndNotify do
  use Jido.Flow,
    name: "greet_and_notify",
    schema: Zoi.object(%{name: Zoi.string()}),
    output_schema: Zoi.map()

  flow do
    step "greet",
      action: MyApp.Actions.GreetUser,
      params: %{name: input(:name), excited?: false}

    step "notify",
      action: MyApp.Actions.Notify,
      params: %{message: select(result("greet"), :greeting)}
  end
end

{:ok, result} =
  Jido.Exec.run(MyApp.Flows.GreetAndNotify, %{name: "Ada"}, %{})
```

The only terminal node is the output when `output` is absent. A Flow with
multiple terminal nodes must declare `output`. Flows also support ordered
Choices, Map and Reduce collections, bounded Iterate nodes with State,
independent nodes that can run in parallel, and a step-wise execution API.

## Build A Flow At Runtime

Use `Jido.Flow.Builder` when runtime data defines the graph. Each node has an
explicit name, and each result reference uses that name.

```elixir
alias Jido.Flow.Builder

builder =
  Builder.new(name: "runtime_greeting")
  |> Builder.step(
    "greet",
    MyApp.Actions.GreetUser,
    %{name: Builder.input(:name), excited?: Builder.value(false)}
  )
  |> Builder.return(Builder.result("greet"))

{:ok, runtime_flow} = Builder.build(builder)
{:ok, %{greeting: "Hello, Ada."}} =
  Jido.Exec.run(runtime_flow, %{name: "Ada"})
```

The Builder and the Flow module DSL are inputs to the same canonical
constructor and Flow model.

## Load A Flow From JSON Or A Map

Use a versioned stored map when a database, web UI, or AI system defines the
Flow. The host owns a flat `Jido.Flow.Registry` that maps stable identifiers to
trusted Action modules, schemas, and data atoms.

```elixir
registry =
  Jido.Flow.Registry.new!(%{
    "actions/greet-user/v1" => {:action, MyApp.Actions.GreetUser},
    "schemas/empty/v1" => {:schema, []},
    "atoms/excited/v1" => {:atom, :excited?},
    "atoms/name/v1" => {:atom, :name}
  })

{:ok, stored} = Jido.Flow.to_stored_map(runtime_flow, registry)
json = JSON.encode!(stored)
decoded = JSON.decode!(json)

case Jido.Flow.from_stored_map(decoded, registry) do
  {:ok, flow} ->
    Jido.Flow.validate_executable(flow)

  {:error, error} ->
    {:error, Jido.Action.Error.to_map(error)}
end
```

`from_stored_map/2` does not execute the Flow. Invalid or incomplete maps
return a structured error instead of raising. Stored identifiers cannot create
atoms or select a module outside the host Registry.

The Flow module DSL, Builder, and stored Map or JSON decoder are three inputs
to one canonical `%Jido.Flow{}` model. Flow element structs and semantic maps
are inspection views, not additional source languages. Compiler, Map codec,
and graph engine adapter modules are private.

## Run A Flow Step By Step

Run-to-completion and step-wise execution use the same engine:

```elixir
{:ok, execution} = Jido.Exec.start(runtime_flow, %{name: "Ada"})
["greet"] = Jido.Exec.ready(execution)

{:ok, %Jido.Exec.NodeResult{node: "greet"}, execution} =
  Jido.Exec.step(execution, "greet")

:succeeded = Jido.Exec.status(execution)
{:ok, %{greeting: "Hello, Ada."}} = Jido.Exec.result(execution)
```

`wave/1` runs the current ready set. `continue/1` runs until the Flow reaches a
terminal result. Always pass the newest execution value to the next call. The
caller owns this in-memory lifecycle. Jido does not persist or recover it.
Reusing a stale value can run an Action side effect again.

## Observe Execution

Telemetry covers Action, Flow, Flow node, and collection work-unit lifecycles.
Direct Actions and Instructions emit `[:jido, :action, :start]`,
`[:jido, :action, :stop]`, and `[:jido, :action, :error]`. Flows and their
nodes use the `[:jido, :flow]` namespace. Map items, Reduce items, and Iterate
iterations add work-unit spans in that namespace. One `execution_id`
correlates nested work. Step and selected Choice targets emit a Flow target
lifecycle with the Action module and selected option. An Action inside a Flow
does not emit a separate direct Action lifecycle. Telemetry observes execution
only; it does not control scheduling or results.

See [Execution](guides/execution.md) for exact event names, measurements,
metadata, nesting, and step-wise semantics.

## Docs

Start with the runnable [Getting Started](guides/getting-started.livemd)
Livebook. ExDoc adds a **Run in Livebook** link to each `.livemd` guide.

### Core Concepts

- [Migrate To v3](guides/v3-migration.md)
- [Actions](guides/actions.md)
- [Instructions](guides/instructions.md)
- [Flows](guides/flows.md)
- [Execution](guides/execution.md)
- [Schemas & Validation](guides/schemas-validation.md)

### Building Flows

- [Build Your First Flow](guides/build-your-first-flow.livemd)
- [Flow Language Overview](guides/flow-language.livemd)
- [Steps & Outputs](guides/flow-steps.livemd)
- [References & Data Mapping](guides/flow-references.livemd)
- [Dependencies & Parallel Work](guides/flow-dependencies.livemd)
- [Map & Reduce](guides/flow-collections.livemd)
- [Choices & Conditions](guides/flow-choices.livemd)
- [Iterate & State](guides/flow-iterate-state.livemd)
- [Nested Flows](guides/nested-flows.livemd)
- [Flow Modules](guides/flow-modules.md)
- [Stored Flow JSON](guides/flow-storage.md)
- [Runtime Builder](guides/flow-builder.md)
- [Inspecting Flows](guides/flow-inspection.md)

### Operations

- [Executing Flows](guides/flow-execution.livemd)
- [Configuration](guides/configuration.md)
- [Security](guides/security.md)
- [Testing](guides/testing.md)
