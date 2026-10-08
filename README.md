# Jido Action

[![Hex.pm](https://img.shields.io/badge/hex-3.0.0--beta.12-714a96.svg)](https://hex.pm/packages/jido_action)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/jido_action/)
[![CI](https://github.com/agentjido/jido_action/actions/workflows/ci.yml/badge.svg)](https://github.com/agentjido/jido_action/actions/workflows/ci.yml)
[![License](https://img.shields.io/hexpm/l/jido_action.svg)](https://github.com/agentjido/jido_action/blob/main/LICENSE)
[![Website](https://img.shields.io/badge/website-jido.run-0f172a.svg)](https://jido.run)
[![Discord](https://img.shields.io/badge/discord-join-5865F2.svg?logo=discord&logoColor=white)](https://jido.run/discord)

> Validated Actions, declarative Flows, and one execution boundary for Elixir.

Jido Action is the work layer of the [Jido](https://github.com/agentjido/jido)
ecosystem. It gives you three things:

- **Actions**: modules that validate their input, do one unit of work, and
  validate their output.
- **Flows**: validated graphs of Action calls. Write them with a DSL, build
  them from maps at runtime, or load them from JSON.
- **Exec**: one execution boundary for both. It compiles Actions and Flows to
  [Runic](https://github.com/zblanco/runic) workflows and returns structured
  results and errors.

Use it on its own for validated, composable application work, or as the
foundation that Jido agents build on.

> #### Beta {: .warning}
>
> Version 3 is in public beta. The API can change before the stable release.
> Use it for evaluation and controlled trials. If you are upgrading from
> version 2, read the [migration guide](guides/v2-to-v3-migration.md).

## Installation

Add `jido_action` to your dependencies:

```elixir
def deps do
  [
    {:jido_action, "~> 3.0.0-beta.12"}
  ]
end
```

Import the formatter rules so Flow DSL declarations format without
parentheses:

```elixir
# .formatter.exs
[
  import_deps: [:jido_action],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
]
```

## Quick Tour

### Define An Action

An Action declares Zoi schemas for its input and output and implements
`run/2`:

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
    output_schema: Zoi.object(%{greeting: Zoi.string()})

  @impl true
  def run(%{name: name, excited?: excited?}, _context) do
    suffix = if excited?, do: "!", else: "."
    {:ok, %{greeting: "Hello, #{name}#{suffix}"}}
  end
end
```

### Run It

`Jido.Exec.run/4` validates the input, calls `run/2`, validates the output,
and turns every failure into a structured error:

```elixir
{:ok, %{greeting: "Hello, Ada!"}} =
  Jido.Exec.run(MyApp.Actions.GreetUser, %{name: "Ada", excited?: true})

{:error, %Jido.Action.Error.InvalidInputError{}} =
  Jido.Exec.run(MyApp.Actions.GreetUser, %{name: ""})
```

The third argument is a context map for caller data such as request IDs. The
fourth argument takes execution options such as `timeout:` and
`max_attempts:`.

### Compose A Flow

A Flow connects Action calls with references. `input/1` reads Flow input,
`result/2` reads an earlier result, and `output` selects the return value:

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

defmodule MyApp.Flows.Welcome do
  use Jido.Flow,
    name: "welcome",
    schema: Zoi.object(%{name: Zoi.string()})

  flow do
    step "greet",
      action: MyApp.Actions.GreetUser,
      params: %{name: input(:name)}

    step "notify",
      action: MyApp.Actions.Notify,
      params: %{message: result("greet", :greeting)}

    output result("notify")
  end
end

{:ok, %{message: "Hello, Ada.", status: "queued"}} =
  Jido.Exec.run(MyApp.Flows.Welcome, %{name: "Ada"})
```

`"notify"` reads the result of `"greet"`, so it runs after it. Source order
does not create dependencies. Independent steps can run concurrently when
you pass `max_concurrency:`.

For small operations, a step can hold an inline body instead of a named
Action. The body compiles to an ordinary Action:

```elixir
step "shout", greeting <- result("greet", :greeting) do
  {:ok, %{text: String.upcase(greeting)}}
end
```

Flows also support choices, map and reduce over collections, bounded
iteration with state, nested Flows, and runtime dispatch.

### Build Or Load A Flow As Data

The same Flow can come from runtime data instead of a module:

```elixir
alias Jido.Flow.Ref

{:ok, flow} =
  Jido.Flow.new(%{
    name: "runtime_greeting",
    components: [
      %{
        kind: :step,
        name: "greet",
        action: MyApp.Actions.GreetUser,
        params: %{name: Ref.input(:name)}
      }
    ],
    output: Ref.result("greet")
  })

{:ok, %{greeting: "Hello, Ada."}} = Jido.Exec.run(flow, %{name: "Ada"})
```

To store a Flow or accept one from a UI or an AI model, encode it with
`Jido.Flow.Codec`. A `Jido.Flow.Registry` that your application owns maps
stable string identifiers to trusted modules, so stored data can never name an
arbitrary module or create atoms:

```elixir
registry =
  Jido.Flow.Registry.new!(%{
    "actions/greet-user" => {:action, MyApp.Actions.GreetUser},
    "schemas/none" => {:schema, []},
    "atoms/name" => {:atom, :name}
  })

{:ok, document} = Jido.Flow.Codec.encode(flow, registry)
json = JSON.encode!(document)

{:ok, restored} = Jido.Flow.Codec.decode(JSON.decode!(json), registry)
```

## How It Fits Together

```text
Action module | Flow module | %Jido.Flow{} | %Jido.Instruction{}
  -> Jido.Exec resolves the target and its call data
  -> Jido.Exec compiles it to a %Runic.Workflow{}
  -> Runic runs it (immediately, or under a Runic.Runner)
  -> {:ok, value} | {:ok, value, effects} | {:error, exception}
```

| Module | Role |
| --- | --- |
| `Jido.Action` | Defines one validated unit of work. |
| `Jido.Instruction` | Holds one call (target, params, context, metadata) as data. |
| `Jido.Flow` | Defines and validates a graph of Action calls. |
| `Jido.Flow.Codec` and `Jido.Flow.Registry` | Store and load Flows as JSON-safe data. |
| `Jido.Expr` | Evaluates small, data-only expressions in Flow fields. |
| `Jido.Exec` | Compiles and runs Actions and Flows. |

Actions can also return deferred effect requests as a third element:
`{:ok, result, [{:send_email, id}]}`. Exec collects them in a deterministic
order and returns them with the result. It never performs them; your
application does.

For work that must survive restarts, `Jido.Exec.start/6` runs the same target
under a supervised `Runic.Runner` with checkpoints and resume.

## Documentation

Start with these three guides, in order:

1. [Getting Started](guides/getting-started.livemd): define, validate, and
   run an Action (Livebook).
2. [Core Concepts](guides/concepts.md): the mental model for every other
   guide.
3. [Build Your First Flow](guides/build-your-first-flow.livemd): compose
   Actions into a Flow (Livebook).

Then use the [HexDocs sidebar](https://hexdocs.pm/jido_action/) by topic:
Actions, Author Flows, Flows As Data, Run And Operate, Extend, and Reference.
Each `.livemd` guide has a **Run in Livebook** button.

## Jido Ecosystem

- [Jido](https://github.com/agentjido/jido) is the agent framework built on
  this package.
- [jido.run](https://jido.run) has project documentation and news.
- [Jido ecosystem](https://jido.run/ecosystem) lists related packages.
- [Discord](https://jido.run/discord) is the community support channel.

## Contributing

See the [contribution guide](https://github.com/agentjido/jido_action/blob/main/CONTRIBUTING.md).

## License

Copyright 2024-2026 Mike Hostetler. Licensed under the Apache License, Version
2.0. See [LICENSE](LICENSE).
