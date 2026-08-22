# Jido Action

`jido_action` defines validated actions, action call frames, data-first Flows,
and one public execution boundary.

This foundation keeps the action boundary small:

- `Jido.Action` defines a named action with Zoi input and output schemas.
- `Jido.Instruction` captures one requested action call as data.
- `Jido.Flow` composes actions as a validated graph with steps and Choices.
- `Jido.Exec` runs actions, instructions, and Flows, including step-wise Flows.

## Install

```elixir
def deps do
  [
    {:jido_action, "~> 3.0"}
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

The last node is the output when `output` is absent. Flows also support ordered
Choices, Map and Reduce collections, bounded Iterate nodes with State,
implicitly parallel independent nodes, and a step-wise execution API.

## Docs

Start with the runnable [Getting Started](guides/getting-started.livemd)
Livebook. ExDoc adds a **Run in Livebook** link to each `.livemd` guide.

### Core Concepts

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
- [Iterate & State](guides/flow-loops-state.livemd)
- [Nested Flows](guides/nested-flows.livemd)
- [Flow Modules](guides/flow-modules.md)
- [Stored Flow JSON](guides/flow-storage.md)
- [Runtime Builder](guides/flow-builder.md)
- [Inspecting & Storing Flows](guides/flow-inspection.md)

### Operations

- [Executing Flows](guides/flow-execution.livemd)
- [Configuration](guides/configuration.md)
- [Security](guides/security.md)
- [Testing](guides/testing.md)
