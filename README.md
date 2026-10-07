# Jido Action

[![Hex.pm](https://img.shields.io/badge/hex-3.0.0--beta.11-714a96.svg)](https://hex.pm/packages/jido_action)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/jido_action/)
[![CI](https://github.com/agentjido/jido_action/actions/workflows/ci.yml/badge.svg)](https://github.com/agentjido/jido_action/actions/workflows/ci.yml)
[![License](https://img.shields.io/hexpm/l/jido_action.svg)](https://github.com/agentjido/jido_action/blob/main/LICENSE)
[![Website](https://img.shields.io/badge/website-jido.run-0f172a.svg)](https://jido.run)
[![Ecosystem](https://img.shields.io/badge/ecosystem-jido.run-0ea5e9.svg)](https://jido.run/ecosystem)
[![Discord](https://img.shields.io/badge/discord-join-5865F2.svg?logo=discord&logoColor=white)](https://jido.run/discord)

> Validated Actions and data-first Flow composition for Elixir.

`jido_action` is part of the [Jido](https://github.com/agentjido/jido)
ecosystem. See [jido.run](https://jido.run) for the project and its packages.

`jido_action` defines validated Actions, Instructions, declarative Flows, and
one execution boundary.

`Jido.Flow` owns authoring, validation, and lossless Map and JSON definitions.
`Jido.Exec` compiles Actions and Flows to executable Runic workflows. Runic
owns runnable creation, scheduling, retries, timeouts, checkpoints,
persistence, and recovery. A single Action uses the same path as a one-step
Flow.

This foundation keeps the action boundary small:

- `Jido.Action` defines a named action with Zoi input and output schemas.
- `Jido.Action.Inline` lets host DSLs compile inline bodies to normal Actions.
- `Jido.Expr` defines fixed, data-only operations for Flow and host DSLs.
- `Jido.Instruction` resolves one Action or Flow target and captures its call data.
- `Jido.Flow` composes actions as a validated graph of tagged nodes.
- `Jido.Flow.Extension` adds compile-time macros that lower to the normal Flow DSL.
- `Jido.Exec` compiles and runs Actions, Instructions, and Flows through Runic.

Version 3.0.0-beta.11 is a public beta. It includes the declarative Flow DSL,
runtime Flow construction, safe stored Flow maps, and one Flow execution
engine. Recent beta releases add inline Steps, the public
`Jido.Action.Inline` host API, `Jido.Expr`, and
compile-time Flow DSL extensions. The v3 API can still change before the
stable release. The current development branch locks Runic 0.1.0-alpha.11.
Use it for evaluation and controlled trials before you use it for critical
production work. See the [version 2 to version 3 migration guide](guides/v2-to-v3-migration.md)
for the confirmed breaking changes.

## Install

```elixir
def deps do
  [
    {:jido_action, "~> 3.0.0-beta.12"}
  ]
end
```

To keep Flow DSL declarations without parentheses, add `:jido_action` to
`import_deps` in your project's `.formatter.exs`:

```elixir
[
  import_deps: [:jido_action],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
]
```

Keep your existing formatter options and imported dependencies. No formatter
plugin is required. See [Flow Modules](guides/flow-modules.md#format-the-dsl).

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
- `to_json/0`
- `validate_params/1`
- `validate_output/1`
- `run/2`

`to_json/0` returns a JSON-safe Action description with the name,
description, input JSON Schema, and output JSON Schema. Jido builds and stores
this description when it compiles the Action. An empty schema becomes `nil`.
The function raises `ArgumentError` when Zoi cannot project a declared schema
to JSON Schema. This does not stop that Action from compiling or running.
Runtime Zoi validation remains authoritative.

Every Action must implement `run/2`. A missing implementation stops compilation.

An Action can also implement `on_before_validate_params/1` when raw input must
be prepared before Zoi validation. Prefer Zoi coercion and other schema rules
when they can express the required change.

## Run An Action

```elixir
{:ok, %{greeting: "Hello, Ada!"}} =
  Jido.Exec.run(
    MyApp.Actions.GreetUser,
    %{name: "Ada", excited?: true},
    %{request_id: "req-123"}
  )
```

`Jido.Exec` resolves an Instruction, compiles it to a real Runic workflow, and
runs that workflow to completion in an unlinked task under
`Jido.Exec.TaskSupervisor`. The task keeps the caller's group leader. Input
validation, the Action callback, and output validation occur inside the
executable Runic Action node. Code that integrates its own executor can use
`validate_params/1`, `run/2`, and `validate_output/1` directly.

The Action `run/2` callback must return one of:

- `{:ok, result}`
- `{:ok, result, effects}`
- `{:error, reason}`
- `{:error, reason, effects}`

A third success element contains an optional effect list. Exec discards the
third element of an error result. Dynamic control flow belongs in Flow
components such as Choice, Iterate, and Dispatch.

## Run Under A Runic Runner

Use `Jido.Exec.start/6` for managed or durable execution. The host supplies a
supervised `Runic.Runner` and a stable execution ID.

```elixir
{:ok, _pid} =
  Jido.Exec.start(
    MyApp.Runner,
    "greeting-123",
    MyApp.Actions.GreetUser,
    %{name: "Ada"},
    %{request_id: "req-123"},
    checkpoint_strategy: :every_cycle
  )
```

Use `Runic.Runner` to stop, checkpoint, resume, and inspect the execution.
Jido does not keep a second checkpoint or cursor.

Managed execution uses automatic dispatch by default. For stepwise control,
start it with `dispatch_mode: :manual`, then call `Jido.Exec.step/2`. Each call
dispatches one Runic scheduler unit and returns the current
`%Runic.Workflow{}`. See the
[Execution Contract](guides/execution.md#stepwise-execution) for completion,
failure, and durable resume behavior.

## Capture A Call Frame

Use `Jido.Instruction` when the intent to run an executable needs to be passed,
logged, queued, or enriched before execution.

```elixir
instruction =
  Jido.Instruction.new!(
    target: MyApp.Actions.GreetUser,
    params: %{name: "Ada"},
    context: %{request_id: "req-123"}
  )
```

An Instruction holds one Action module, Flow module, or runtime Flow target. It
does not define a workflow, program, or runtime policy.

Pass execution options to `Jido.Exec`.

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

    output result("notify")
  end
end

{:ok, result} =
  Jido.Exec.run(MyApp.Flows.GreetAndNotify, %{name: "Ada"}, %{})
```

Each Flow module and canonical Flow has one explicit output expression. In a
module Flow, `output` must be the final declaration. Flows also support
ordered Choices, Map and Reduce collections, bounded Iterate components with
State, independent components that can run in parallel, one Dispatch at the
end of a Flow, and durable execution through `Runic.Runner`.

### Use Inline Steps For Small Operations

Version `3.0.0-beta.5` adds inline Step bodies for small operations that do not
need a separate named Action.

```elixir
defmodule MyApp.Flows.SimpleGreeting do
  use Jido.Flow,
    name: "simple_greeting",
    schema: Zoi.object(%{name: Zoi.string()}),
    output_schema: Zoi.object(%{message: Zoi.string()})

  flow do
    step "normalize", name <- input(:name) do
      {:ok, %{name: String.trim(name)}}
    end

    step "greet", name <- result("normalize", :name) do
      {:ok, %{message: "Hello, " <> name <> "!"}}
    end

    output result("greet")
  end
end

{:ok, %{message: "Hello, Ada!"}} =
  Jido.Exec.run(MyApp.Flows.SimpleGreeting, %{name: " Ada "})
```

Binding sources use direct Flow references or data. Bodies use normal Elixir and
compile to ordinary Actions. Use `inline:` to set the Action name, description,
schemas, or context binding. Keep Step `needs:` and `meta:` options at the Step
level.
Use `MyApp.Flows.SimpleGreeting.step_action("greet")` to reuse its target in
data definitions or a trusted Registry. Data definitions and JSON do not accept body code,
closures, or MFAs. See [Build Your First Flow](guides/build-your-first-flow.livemd).

Flow inline Actions are limited to direct Step bodies. Map, Reduce, Choice,
Iterate, and Dispatch use Action modules. The separate
[`Jido.Action.Inline` host API](guides/building-dsls-with-inline-actions.md)
lets downstream compile-time DSLs define their own inline Action forms without
Flow. Keep a named Action for custom validation hooks or a separate public
module API.

## Build A Flow At Runtime

Use `Jido.Flow.new/1` when runtime data defines the graph. Each node has an
explicit name, and each result reference uses that name.

```elixir
data = %{
  output: Jido.Flow.Ref.result("greet"),
  components: [
    %{
      kind: :step,
      name: "greet",
      action: MyApp.Actions.GreetUser,
      params: %{name: Jido.Flow.Ref.input(:name), excited?: false}
    }
  ],
  name: "runtime_greeting"
}

{:ok, runtime_flow} = Jido.Flow.new(data)
{:ok, %{greeting: "Hello, Ada."}} = Jido.Exec.run(runtime_flow, %{name: "Ada"})
```

The data definitions and the Flow module DSL produce the same canonical Flow
model. The authoring list becomes a map keyed by component name. Call nodes
keep an inert `Jido.Instruction` template and the parameter expression in one
tuple. Exec binds evaluated params, context, and runtime location data before
it invokes the target.

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

{:ok, stored} = Jido.Flow.Codec.encode(runtime_flow, registry)
json = JSON.encode!(stored)
decoded = JSON.decode!(json)

case Jido.Flow.Codec.decode(decoded, registry) do
  {:ok, flow} ->
    Jido.Exec.compile(flow)

  {:error, error} ->
    {:error, Jido.Flow.Error.to_map(error)}
end
```

For temporary storage or transport within one application version, the Codec
can generate and return a Registry:

```elixir
{:ok, stored, temporary_registry} = Jido.Flow.Codec.encode(runtime_flow)
{:ok, restored} = Jido.Flow.Codec.decode(stored, temporary_registry)
```

Generated identifiers can change when the Flow changes. Use an
application-owned Registry for durable storage.

`Jido.Flow.Codec.decode/2` does not execute the Flow. Invalid or incomplete maps
return a structured error instead of raising. Stored identifiers cannot create
atoms or select a module outside the host Registry.

Use `Jido.Flow.Codec.diagnose/2` for a browser or AI editor that needs all
independent stored-document and graph errors. It returns one ordered Splode
error group with JSON paths and never returns a partial Flow.

The Flow module DSL, map definitions, and stored JSON Codec produce one
canonical `%Jido.Flow{}` model. The Codec uses explicit component kinds. It
does not infer old records or module names.

## Compile And Inspect A Flow

`Jido.Exec.compile/2` returns the executable `Runic.Workflow`:

```elixir
{:ok, workflow} = Jido.Exec.compile(runtime_flow)
```

Use Runic's public workflow and Runner APIs to inspect runnable state,
lifecycle events, checkpoints, and results. Jido does not define a parallel
execution struct or work-token API. See [Debug Flows](guides/debugging-flows.md).

## Docs

Start with the runnable [Getting Started](guides/getting-started.livemd)
Livebook. ExDoc adds a **Run in Livebook** link to each `.livemd` guide.

### Start Here

- [Build Your First Flow](guides/build-your-first-flow.livemd)

### Core Contracts

- [Actions](guides/actions.md)
- [Inline Actions](guides/inline-actions.md)
- [Building DSLs With Inline Actions](guides/building-dsls-with-inline-actions.md)
- [Instructions](guides/instructions.md)
- [Flows](guides/flows.md)
- [Dynamic Flows](guides/dynamic-flows.md)
- [Schemas & Validation](guides/schemas-validation.md)
- [Execution Contract](guides/execution.md)
- [Public Contract Register](guides/public-contracts.md)

### Author Flows

- [Flow DSL](guides/flow-language.livemd)
- [Steps And Output](guides/flow-steps.livemd)
- [References And Data](guides/flow-references.livemd)
- [Expressions And Host DSLs](guides/flow-expressions.md)
- [Dependencies And Parallel Work](guides/flow-dependencies.livemd)
- [Choices And Conditions](guides/flow-choices.livemd)
- [Map And Reduce](guides/flow-collections.livemd)
- [Iterate And State](guides/flow-iterate-state.livemd)
- [Nested Flows](guides/nested-flows.livemd)
- [Flow Modules](guides/flow-modules.md)
- [Flow Data Definitions](guides/flow-data.md)
- [Store Flows As JSON](guides/flow-storage.md)
- [Inspect Flows](guides/flow-inspection.md)

### Run And Operate

- [Executing Flows](guides/flow-execution.livemd)
- [Maps, Streams, And Optional Effects](guides/action-effects.livemd)
- [Debug Flows](guides/debugging-flows.md)
- [Runtime Configuration](guides/configuration.md)
- [Security](guides/security.md)
- [Testing](guides/testing.md)
- [Execution Benchmarks](guides/benchmarks.md)

### Upgrade

- [Version 2 To Version 3 Migration Guide](guides/v2-to-v3-migration.md)
- [Upgrade From v2 To v3 Skill](guides/v2-to-v3-upgrade-skill.md)

## Jido Ecosystem

- [Jido](https://github.com/agentjido/jido) is the core agent framework.
- [Jido website](https://jido.run) contains project documentation and news.
- [Jido ecosystem](https://jido.run/ecosystem) lists the related packages.
- [Jido Workbench](https://github.com/agentjido/jido_workbench) provides
  development and inspection tools.
- [Jido Discord](https://jido.run/discord) is the community support channel.

## Contributing

See the [contribution guide](https://github.com/agentjido/jido_action/blob/main/CONTRIBUTING.md)
for development and pull-request guidance.

## License

Copyright 2024-2026 Mike Hostetler

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE).

## Deferred Effect Requests

Return `{:ok, output, requests}` from an Action to
request effects after success. Flow collects these opaque requests in canonical
dependency order and returns the complete batch with its final output. Exec
does not execute effects. Failed execution returns no executable batch.
The optional third success element must be a proper list of effect requests.
Run [Maps, Streams, And Optional Effects](guides/action-effects.livemd) for
complete order approval and CSV export examples with integration tests.
See [Execution](guides/execution.md#results-and-errors) for ordering,
collections, and error behavior.
