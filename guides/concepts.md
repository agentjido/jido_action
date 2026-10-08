# Core Concepts

This guide gives you the mental model for Jido Action. Read it after
[Getting Started](getting-started.livemd) and before the detailed guides.

## The Short Version

Jido Action has four public parts and one engine underneath them:

| Part | What it is | You use it to |
| --- | --- | --- |
| `Jido.Action` | A module with an input schema, an output schema, and `run/2`. | Define one validated unit of work. |
| `Jido.Instruction` | A struct with a target, params, context, and metadata. | Describe one call as data before you run it. |
| `Jido.Flow` | A validated graph of Action calls with one explicit output. | Compose Actions declaratively. |
| `Jido.Exec` | The execution boundary. | Validate, run, and return structured results. |
| Runic | The workflow engine that `Jido.Exec` compiles to. | Schedule work, retry, checkpoint, and resume. |

The basic loop is always the same:

```text
Action module, Flow module, %Jido.Flow{}, or %Jido.Instruction{}
  -> Jido.Exec resolves it to an Instruction
  -> Jido.Exec compiles it to a %Runic.Workflow{}
  -> Runic runs the workflow
  -> {:ok, value} | {:ok, value, effects} | {:error, exception}
```

An Action is a one-node workflow. A Flow is a larger workflow. There is only
one execution path.

## Actions: Validated Work

An Action is a module that uses `Jido.Action`. It declares a name, an optional
description, a Zoi input `schema`, and a Zoi `output_schema`. It implements
`run(params, context)`.

```elixir
defmodule MyApp.Actions.Add do
  use Jido.Action,
    name: "add",
    schema: Zoi.object(%{left: Zoi.integer(), right: Zoi.integer()}),
    output_schema: Zoi.object(%{sum: Zoi.integer()})

  @impl true
  def run(%{left: left, right: right}, _context) do
    {:ok, %{sum: left + right}}
  end
end
```

Three ideas matter:

- **Params are validated data.** `Jido.Exec` validates input before `run/2`
  and validates output after it. A direct `run/2` call skips validation.
- **Context is caller data.** Use it for request IDs, tenants, and other values
  that are not part of the Action's input contract.
- **The result is a map.** A normal success is `{:ok, map}`. Use
  `Jido.Action.Output` when a success value is intentionally a raw value, a
  stream, a batch, or an opaque value.

See [Actions](actions.md) and [Schemas And Validation](schemas-validation.md).

## Instructions: A Call As Data

An Instruction holds one target and its call data:

```elixir
instruction =
  Jido.Instruction.new!(
    target: MyApp.Actions.Add,
    params: %{left: 1, right: 2},
    context: %{request_id: "req-1"}
  )

{:ok, %{sum: 3}} = Jido.Exec.run(instruction)
```

Use an Instruction when a call must be built in one place and run in another,
for example after it is logged, queued, or enriched. `Jido.Exec.run/4` also
accepts a bare Action module and builds the Instruction for you.

An Instruction has no runtime policy. Pass options such as `timeout:` to
`Jido.Exec`. See [Instructions](instructions.md).

## Flows: Composition As Data

A Flow is a named graph of components. Each component has a unique string
name. The Flow has one required `output` expression.

```elixir
defmodule MyApp.Flows.AddThenDouble do
  use Jido.Flow,
    name: "add_then_double",
    schema: Zoi.object(%{left: Zoi.integer(), right: Zoi.integer()})

  flow do
    step "add",
      action: MyApp.Actions.Add,
      params: %{left: input(:left), right: input(:right)}

    step "double", sum <- result("add", :sum) do
      {:ok, %{value: sum * 2}}
    end

    output result("double")
  end
end

{:ok, %{value: 6}} = Jido.Exec.run(MyApp.Flows.AddThenDouble, %{left: 1, right: 2})
```

Read the Flow from its references:

- `input(:left)` reads Flow input.
- `result("add", :sum)` reads the `:sum` field from the `"add"` result.
- A result reference creates a dependency. Source order does not.
- `output` selects the value that the Flow returns.

A step can call a named Action (`action:` and `params:`) or contain a small
inline body. An inline body compiles to an ordinary Action.

### Component Kinds

| Component | Use it to |
| --- | --- |
| `step` | Call one Action or one child Flow. |
| `choice` | Run the first option whose condition is true, or a fallback. |
| `map` | Run one Action for each item in a collection. |
| `reduce` | Fold a collection through one Action, in order. |
| `iterate` | Repeat one Action with local state until a bounded condition ends. |
| `dispatch` | Let runtime data select the next Action or Flow, at the end of a Flow. |

Conditions and small calculations use `Jido.Expr`, a restricted, data-only
expression grammar. Real work belongs in Actions.

### Three Ways To Author One Flow

| Form | Use it when | Entry point |
| --- | --- | --- |
| Module DSL | You write the Flow in source code. This is the normal choice. | `use Jido.Flow` |
| Data definition | Application code builds the graph at runtime. | `Jido.Flow.new/1` |
| Stored JSON | A database, UI, or AI system supplies the Flow. | `Jido.Flow.Codec.decode/2` |

All three produce the same canonical `%Jido.Flow{}` value with the same
validation rules. Stored JSON cannot name arbitrary modules or create atoms.
A host-owned `Jido.Flow.Registry` maps stable identifiers to trusted modules.

See [Flows](flows.md), [Flow Data Definitions](flow-data.md), and
[Store Flows As JSON](flow-storage.md).

## Exec: One Execution Boundary

`Jido.Exec` has two ways to run work.

**Immediate execution** runs to completion and returns the result:

```elixir
Jido.Exec.run(target, params, context, timeout: 5_000, max_concurrency: 4)
```

The work runs in a supervised task. If the caller exits, the work stops. This
is the right choice for most application code and tests.

**Managed execution** runs under a supervised `Runic.Runner` with a stable
execution ID:

```elixir
Jido.Exec.start(MyApp.Runner, "order-42", MyApp.Flows.ProcessOrder, params, context)
```

Runic owns the worker, its checkpoints, and recovery. Use managed execution
when work must survive a restart, when you want to step through it, or when
another process must observe it. See [Managed Execution](managed-execution.md).

`Jido.Exec.compile/2` returns the `%Runic.Workflow{}` without running it. Use it
to check targets and inspect the executable graph.

## Results, Errors, And Effects

Every run returns one of three shapes:

```elixir
{:ok, value}
{:ok, value, effects}
{:error, exception}
```

- `value` is the validated Action output or the Flow output.
- `effects` is a list of requests that Actions returned as a third element,
  such as `{:ok, result, [{:send_email, id}]}`. Exec does not perform them.
  Your application does, after it accepts the result. A failed run returns no
  effects.
- `exception` is a `Jido.Action.Error` or `Jido.Flow.Error` struct. Use
  `Exception.message/1` for people and `to_map/1` for logs and APIs.

See [Outputs And Effects](action-effects.livemd) and [Errors](errors.md).

## Who Owns What

| Concern | Owner |
| --- | --- |
| Input and output validation | Jido (Action and Flow schemas) |
| Graph structure, references, and expressions | Jido (`Jido.Flow`) |
| Scheduling, concurrency, timeouts, and retries | Runic, configured through `Jido.Exec` options |
| Checkpoints, persistence, and resume | Runic (`Runic.Runner` and its Store) |
| Performing effects, authorization, and secrets | Your application |
| Durable orchestration policy across many calls | A higher-level runtime, such as Jido agents |

## Which API Do I Use?

| I want to | Use |
| --- | --- |
| Run one unit of work with validation | `Jido.Exec.run(MyAction, params, context)` |
| Pass a call around before running it | `Jido.Instruction.new!/1`, then `Jido.Exec.run/4` |
| Compose several Actions in code | A Flow module with `use Jido.Flow` |
| Build a graph from runtime data | `Jido.Flow.new/1` |
| Store or load a Flow as JSON | `Jido.Flow.Codec` with a `Jido.Flow.Registry` |
| Check a Flow without running it | `Jido.Flow.validate/1`, then `Jido.Exec.compile/2` |
| Run work that survives restarts | `Jido.Exec.start/6` under a `Runic.Runner` |
| Describe an Action to a tool or model | `MyAction.to_json/0` |
| Add inline Actions to my own DSL | `Jido.Action.Inline` |

## Next

- [Build Your First Flow](build-your-first-flow.livemd) for a hands-on Flow.
- [Actions](actions.md) for the complete Action contract.
- [Flow DSL Tour](flow-language.livemd) for every Flow component.
- [Execution](execution.md) for options, process behavior, and telemetry.
