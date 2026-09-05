# Jido Action

[![Hex.pm](https://img.shields.io/badge/hex-3.0.0--beta.6-714a96.svg)](https://hex.pm/packages/jido_action)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/jido_action/3.0.0-beta.6/)
[![CI](https://github.com/agentjido/jido_action/actions/workflows/ci.yml/badge.svg)](https://github.com/agentjido/jido_action/actions/workflows/ci.yml)
[![License](https://img.shields.io/hexpm/l/jido_action.svg)](https://github.com/agentjido/jido_action/blob/main/LICENSE)
[![Website](https://img.shields.io/badge/website-jido.run-0f172a.svg)](https://jido.run)
[![Ecosystem](https://img.shields.io/badge/ecosystem-jido.run-0ea5e9.svg)](https://jido.run/ecosystem)
[![Discord](https://img.shields.io/badge/discord-join-5865F2.svg?logo=discord&logoColor=white)](https://jido.run/discord)

> Validated Actions and data-first Flow composition for Elixir.

`jido_action` is part of the [Jido](https://github.com/agentjido/jido)
ecosystem. See [jido.run](https://jido.run) for the project and its packages.

`jido_action` defines validated actions, executable call frames, data-first Flows,
and one public execution boundary.

Jido Flow is a declarative, in-memory graph execution layer for Jido Actions.
Runic owns graph mechanics, planning, runnable discovery, node execution, and
graph-state transitions. Jido Flow owns its DSL, validation, lossless Map/JSON
representation, compilation, and Flow semantics. Jido Exec owns one in-memory
execution session: step-wise execution, bounded concurrency, Action invocation,
errors, telemetry, and final results.

Durable orchestration is not provided. An outer system must own persistence,
queues, scheduling, recovery, retries, durable cancellation policy,
distributed coordination, supervision, and deployment-safe continuation.
`Jido.Exec` can enforce one caller-selected timeout for a complete in-memory
call. It can also return an owner-bound handle for one asynchronous call.

This foundation keeps the action boundary small:

- `Jido.Executable` is the advanced descriptor API for the common Action and
  Flow target contract.
- `Jido.Action` defines a named action with Zoi input and output schemas.
- `Jido.Action.Inline` lets host DSLs compile inline bodies to normal Actions.
- `Jido.Expr` defines fixed, data-only operations for Flow and host DSLs.
- `Jido.Instruction` captures one requested executable call as data.
- `Jido.Flow` composes actions as a validated graph with steps and Choices.
- `Jido.Exec` runs actions, instructions, and Flows, including asynchronous
  run-to-completion calls and step-wise Flows.

Version 3.0.0-beta.6 is a public beta. It includes the declarative Flow DSL,
runtime Flow construction, safe stored Flow maps, and one Flow execution
engine. This beta adds portable inline Actions and `Jido.Expr`. The v3 API can
still change before the stable release. The current development branch locks
Runic 0.1.0-alpha.10. Use it for evaluation and controlled trials before you
use it for critical production work. See the [version 2 to version 3 migration
guide](guides/v2-to-v3-migration.md) for the confirmed breaking changes.

## Install

```elixir
def deps do
  [
    {:jido_action, "~> 3.0.0-beta.6"}
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
- `validate_params/1`
- `validate_output/1`
- `run/2`

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

`Jido.Exec` validates the Action input and output and runs the Action under the
configured Task Supervisor. Code that integrates its own executor can use
`validate_params/1`, `run/2`, and `validate_output/1` directly.

The Action `run/2` callback must return one of:

- `{:ok, result}`
- `{:ok, result, extra}`
- `{:continue, input, target}`
- `{:error, reason}`
- `{:error, reason, extra}`

The `{:continue, input, target}` result ends the current executable and runs
the selected Action or Flow in the same bounded Exec call. Normal success and
error three-tuples let callers receive an extra value. See
[Continue to Another Executable](guides/continuations.md).

## Run Asynchronously

`run_async/4` accepts the same run-to-completion targets and options as
`run/4`. It returns a handle immediately.

```elixir
handle =
  Jido.Exec.run_async(
    MyApp.Actions.GreetUser,
    %{name: "Ada", excited?: true},
    %{request_id: "req-123"}
  )

{:ok, %{greeting: "Hello, Ada!"}} = Jido.Exec.await(handle)
```

The process that calls `run_async/4` owns the handle. Only that process can
call `await/1`, `await/2`, `handle_message/2`, or `cancel/1`. Use
`handle_message/2` to classify messages in an OTP callback without blocking:

```elixir
def handle_info(message, %{handle: handle} = state) do
  case Jido.Exec.handle_message(handle, message) do
    {:done, result} -> {:noreply, %{state | handle: nil, result: result}}
    :ignore -> {:noreply, state}
    {:error, error} -> {:stop, error, state}
  end
end
```

`await/2`, `handle_message/2`, and `cancel/1` are alternative one-shot
terminal consumers. The default wait limit for `await/1` is 5 seconds. An
`await/2` timeout cancels the work. The `timeout:` run option is a separate
limit for the complete execution.

`cancel/1` stops active in-memory Action and Flow work. It cannot undo side
effects that already completed.

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
Flow modules provide a definition through `flow/0` and share the Executable
validation callbacks. Their generated `run/2` delegates to Exec as a convenience.

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

Every Flow declares one output expression. Flows also support ordered Choices,
Map and Reduce collections, bounded Iterate components with State, independent
components that can run in parallel, one Dispatch at the end of a Flow, and a
step-wise execution API.

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

Binding sources use Flow data expressions. Bodies use normal Elixir and
compile to ordinary Actions. This shipped shorthand has empty field schemas
and accepts only Step `after:` and `meta:` options.
Use `MyApp.Flows.SimpleGreeting.step_action("greet")` to reuse its target in
Builder or a trusted Registry. Neither Builder nor JSON accepts body code,
closures, or MFAs. See [Build Your First Flow](guides/build-your-first-flow.livemd).

Version `3.0.0-beta.6` adds the
[portable inline Action API](guides/inline-actions.md), with
nested blocks for Step, Map, Reduce, Choice options and fallback, Iterate,
and Dispatch. These blocks accept explicit schemas, metadata, and execution
context. A downstream DSL can use `Jido.Action.Inline` without Flow. The same
release adds `Jido.Expr` for portable calculations. Keep a named Action for
custom validation hooks or a separate public module API.

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
  |> Builder.output(Builder.result("greet"))

{:ok, runtime_flow} = Builder.build(builder)
{:ok, %{greeting: "Hello, Ada."}} =
  Jido.Exec.run(runtime_flow, %{name: "Ada"})
```

The Builder and the Flow module DSL produce the same canonical Flow model.

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
    Jido.Flow.validate_executable(flow)

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

The Flow module DSL, Builder, stored JSON Codec, and direct constructors produce
one canonical `%Jido.Flow{}` model. The Codec uses explicit component kinds.
It does not infer old records or module names.

## Run A Flow Step By Step

Run-to-completion and step-wise execution use the same engine:

```elixir
{:ok, execution} = Jido.Exec.start(runtime_flow, %{name: "Ada"})
[runnable] = Jido.Exec.ready(execution)

%Runic.Workflow{} = Jido.Exec.workflow(execution)
%Jido.Flow.Compiled{} = Jido.Exec.compiled(execution)

{:ok, %Runic.Workflow.Runnable{status: :completed}, execution} =
  Jido.Exec.step(execution, runnable)

:succeeded = Jido.Exec.status(execution)
{:ok, %{greeting: "Hello, Ada."}} = Jido.Exec.result(execution)
```

`wave/1` runs work from the current ready set. A failed runnable stops new
dispatch; work already admitted can finish. `continue/1` runs until the Flow
reaches a terminal result. Always pass the newest execution value to the next
call. The caller owns this in-memory lifecycle. Jido does not persist or recover it.
Jido rejects reuse of a stale execution revision.

## Observe Execution

Telemetry covers Action, Flow, Flow node, and collection work-unit lifecycles.
Direct Actions and Instructions emit `[:jido, :action, :start]`,
`[:jido, :action, :stop]`, and `[:jido, :action, :error]`. Flows and their
nodes use the `[:jido, :flow]` namespace. Map items, Reduce items, and Iterate
iterations add work-unit spans in that namespace. One `execution_id`
correlates nested work. Step and selected Choice Actions emit a target
lifecycle with the Action module and selected option. An Action inside a Flow
does not emit a separate direct Action lifecycle. Telemetry observes execution
only; it does not control scheduling or results. A complete-call timeout closes
all active Jido spans with an error event.

See [Execution](guides/execution.md) for exact event names, measurements,
metadata, nesting, and step-wise semantics.

## Docs

Start with the runnable [Getting Started](guides/getting-started.livemd)
Livebook. ExDoc adds a **Run in Livebook** link to each `.livemd` guide.

### Start Here

- [Build Your First Flow](guides/build-your-first-flow.livemd)

### Core Contracts

- [Actions](guides/actions.md)
- [Portable Inline Actions](guides/inline-actions.md)
- [Instructions](guides/instructions.md)
- [Flows](guides/flows.md)
- [Continue to Another Executable](guides/continuations.md)
- [Schemas & Validation](guides/schemas-validation.md)
- [Execution Contract](guides/execution.md)

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
- [Direct Construction And Builder](guides/flow-builder.md)
- [Store Flows As JSON](guides/flow-storage.md)
- [Inspect Flows](guides/flow-inspection.md)

### Run And Operate

- [Executing Flows](guides/flow-execution.livemd)
- [Debug Flows](guides/debugging-flows.md)
- [Runtime Configuration](guides/configuration.md)
- [Security](guides/security.md)
- [Testing](guides/testing.md)

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
