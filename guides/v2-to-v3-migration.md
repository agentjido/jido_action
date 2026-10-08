# Version 2 To Version 3 Migration Guide

This guide moves an application from `jido_action` `2.3.2` to
`3.0.0-beta.12`. Read [Core Concepts](concepts.md) first if you are new to the
version 3 model.

Each section shows version 2 code that no longer works the same way, then the
version 3 replacement. New version 3 features that need no change to version 2
code are out of scope. If you already use an earlier version 3 beta, skip to
[Upgrading From Earlier v3 Betas](#upgrading-from-earlier-v3-betas).

Upgrade one area at a time. Compile and test the application after each area.

## Update The Dependency

Change the package version in `mix.exs`:

```elixir
def deps do
  [
    {:jido_action, "~> 3.0.0-beta.12"}
  ]
end
```

Version 3 no longer depends on NimbleOptions, Req, Lua, Multigraph, or
Igniter. Add a direct dependency for each one that your application code still
calls. `jido_action` still lists Jason as a dependency today, but declare Jason
yourself if your code calls it.

## Replace Version 2 Action Options And Schemas

Version 2 accepts Action metadata, compensation settings, NimbleOptions
schemas, and Zoi schemas:

```elixir
defmodule MyApp.Actions.CreateOrder do
  use Jido.Action,
    name: "create_order",
    description: "Creates an order",
    category: "orders",
    tags: ["write"],
    vsn: "2",
    compensation: [enabled: true, timeout: 5_000],
    schema: [
      customer_id: [type: :string, required: true]
    ],
    output_schema: [
      order_id: [type: :string, required: true]
    ]

  @impl true
  def run(params, _context) do
    {:ok, %{order_id: create_order(params.customer_id)}}
  end
end
```

Version 3 accepts only `name`, `description`, `schema`, and `output_schema`.
Each schema is a map-shaped Zoi schema. An empty list means that the Action
has no declared field schema.

### What You Need To Change

Remove `category`, `tags`, `vsn`, and `compensation` from `use Jido.Action`.
Convert each NimbleOptions schema to Zoi:

```elixir
defmodule MyApp.Actions.CreateOrder do
  use Jido.Action,
    name: "create_order",
    description: "Creates an order",
    schema:
      Zoi.object(%{
        customer_id: Zoi.string()
      }),
    output_schema:
      Zoi.object(%{
        order_id: Zoi.string()
      })

  @impl true
  def run(params, _context) do
    {:ok, %{order_id: create_order(params.customer_id)}}
  end
end
```

Keep application metadata in an application module or in plain module
functions. Move compensation policy to the caller or to the runtime that owns
the complete operation.

## Make Action Schemas Static

Version 2 accepts schema values that contain anonymous functions, lazy
schemas, process values, or other runtime-only data. Version 3 rejects these
values when it compiles an Action.

### What You Need To Change

Replace an anonymous Zoi effect with a named MFA effect:

```elixir
defmodule MyApp.Actions.CreateOrder do
  use Jido.Action,
    name: "create_order",
    schema:
      Zoi.object(%{
        customer_id:
          Zoi.string()
          |> Zoi.refine({__MODULE__, :not_blank, []})
      })

  def not_blank(value, _opts) do
    if String.trim(value) == "", do: {:error, "cannot be blank"}, else: :ok
  end

  @impl true
  def run(params, _context), do: {:ok, params}
end
```

Build runtime-dependent input before the Action call. Do not store a process,
reference, port, or anonymous function in an Action schema.

## Declare The Unknown-Key Policy For Nested Data

Version 3 preserves unknown keys at the root of an Action object or struct
schema. Nested and wrapped schemas use their declared Zoi unknown-key policy.
Code that relied on the version 2 open behavior can lose or reject nested keys
after the upgrade.

### What You Need To Change

Set `unrecognized_keys: :preserve` on each nested object that must keep its
unknown keys:

```elixir
schema:
  Zoi.object(%{
    customer:
      Zoi.object(
        %{name: Zoi.string()},
        unrecognized_keys: :preserve
      )
  })
```

Use `:error` when an unknown nested key must fail validation. Use the Zoi
default only when stripping unknown nested keys is correct.

## Remove Five Action Lifecycle Hooks

Version 3 keeps `on_before_validate_params/1`. It runs before the input Zoi
schema. Keep it only when raw input must change before Zoi can parse it.

Version 3 removes these callbacks:

- `on_after_validate_params/1`
- `on_before_validate_output/1`
- `on_after_validate_output/1`
- `on_after_run/1`
- `on_error/4`

### What You Need To Change

Move each removed hook to the boundary that owns its work:

| Version 2 hook | Version 3 location |
| --- | --- |
| `on_after_validate_params/1` | The start of `run/2` |
| `on_before_validate_output/1` | Build the final result in `run/2` |
| `on_after_validate_output/1` | Build the final result in `run/2`, then let the output schema validate it |
| `on_after_run/1` | `run/2` or the caller |
| `on_error/4` | The caller or a higher-level runtime |

Prefer Zoi coercion, defaults, enums, and refinements when they can express
the input rule. Put Action-owned authentication, authorization, and secret
lookup in `run/2`. Do not put I/O, retry, rollback, or compensation in
`on_before_validate_params/1`.

## Replace Generated Action Metadata And Tool Functions

Version 3 no longer generates these version 2 functions:

- `category/0`, `tags/0`, and `vsn/0`
- `to_tool/0`
- `__action_metadata__/0`

`Jido.Exec` also stops adding `:action_metadata` to the Action context.

### What You Need To Change

Replace calls to `category/0`, `tags/0`, and `vsn/0` with application-owned
metadata. Pass required invocation data in the Action context.

Version 3 `to_json/0` is a smaller provider-neutral description. It contains
the Action name, description, input JSON Schema, and output JSON Schema. It
does not restore version 2 categories, tags, versions, execution policy, or
tool data.

Move AI tool conversion to the package that owns the AI integration. That
adapter can read `to_json/0`, then call `Jido.Exec.run/4`. ReqLLM owns the
generic Tool type and provider-specific tool formats. Jido AI owns the adapter
from a Jido Action to a ReqLLM Tool and owns execution of the selected Action.

If you use Jido AI, replace the generated function with the Jido AI adapter:

```elixir
# Version 2
tool = MyApp.Actions.Search.to_tool()

# Version 3
tool = Jido.AI.ToolAdapter.from_action(MyApp.Actions.Search)
```

Use a Jido AI release that supports `jido_action` version 3. It must not
depend on the removed `Jido.Action.Schema` or `Jido.Action.Tool` modules.

## Return Effects As A List

Version 2 accepts any third success element, such as a directive:
`{:ok, result, extras}`. Version 3 reserves the third element for a proper
list of effect requests. Any other value fails with an
`ExecutionFailureError` whose `details.reason` is `:invalid_effects`.

### What You Need To Change

Wrap a single extra value in a list, or move metadata into the result map:

```elixir
# Version 2
{:ok, result, directive}

# Version 3
{:ok, result, [directive]}
```

Exec returns the list to the caller and never performs it. See
[Outputs And Effects](action-effects.livemd) for ordering and failure rules.

## Replace Instruction Fields

A version 2 Instruction stores Action-specific fields:

```elixir
Jido.Instruction.new!(
  id: "send-1",
  action: MyApp.Actions.SendEmail,
  params: %{to: "user@example.com"},
  context: %{tenant_id: "tenant-1"},
  opts: [timeout: 5_000]
)
```

A version 3 Instruction stores one executable target. You pass execution
options to `Jido.Exec`:

```elixir
instruction =
  Jido.Instruction.new!(
    target: MyApp.Actions.SendEmail,
    params: %{to: "user@example.com"},
    context: %{tenant_id: "tenant-1"},
    metadata: %{id: "send-1"}
  )

Jido.Exec.run(instruction, %{}, %{}, timeout: 5_000)
```

### What You Need To Change

Apply these field changes:

| Version 2 field | Version 3 field or location |
| --- | --- |
| `action` | `target` |
| `id` | Caller-owned data, or `metadata` when it is descriptive |
| `params` | `params` |
| `context` | `context` |
| `opts` | Options passed to `Jido.Exec.run/4` |

Constructors reject the removed `:id`, `:action`, `:flow`, and `:opts` fields.
See [Replace The Exec Options](#replace-the-exec-options) for the supported
options.

## Replace Instruction Shorthand And Allowlists

Version 3 removes these version 2 functions and input forms:

- `normalize/3` and `normalize_single/3`
- The version 2 list-return behavior of `normalize!/3`
- Module, tuple, and list shorthand
- `validate_allowed_actions/2`

### What You Need To Change

Build each Instruction explicitly:

```elixir
# Version 2
{:ok, instructions} =
  Jido.Instruction.normalize([
    MyApp.Actions.FetchOrder,
    {MyApp.Actions.SaveOrder, %{id: "order-1"}}
  ])

# Version 3
instructions = [
  Jido.Instruction.new!(target: MyApp.Actions.FetchOrder),
  Jido.Instruction.new!(
    target: MyApp.Actions.SaveOrder,
    params: %{id: "order-1"}
  )
]
```

When a target name comes from an external boundary, resolve it through an
application allowlist before you build the Instruction. Do not create an atom
from external input.

## Replace The Exec Options

`Jido.Exec.run/4` is still the immediate execution entry point. Version 3
compiles every Action or Flow to a Runic workflow and runs it. Runic applies
the timeout and retry policy to each runnable. A runnable is one unit of
scheduled work, such as one Action call or one internal Flow node.

```elixir
Jido.Exec.run(MyApp.Actions.CreateOrder, params, context,
  timeout: 30_000,
  max_attempts: 3,
  backoff: :exponential,
  base_delay_ms: 50,
  max_delay_ms: 2_000
)
```

The timeout is a per-attempt Runic timeout. `max_attempts` includes the first
attempt. Runic owns retry and backoff. Exec retries only errors that set
`details.retry: true`.

### What You Need To Change

Map each version 2 option to its version 3 form:

| Version 2 | Version 3 |
| --- | --- |
| `timeout:` (default `30_000`, whole Action) | `timeout:` (default `:infinity`, each attempt of each runnable) |
| `max_retries: n` (default `1`) | `max_attempts: n + 1` (default `1`, no retry) |
| `backoff: ms` (initial delay, doubles) | `backoff: :exponential` with `base_delay_ms:` and `max_delay_ms:` |
| `log_level:` | Removed. Configure Logger. |
| `:jido_action` application config defaults | Removed. Pass options on each call. |

Check these behavior changes:

- Version 3 has no default timeout. Set `timeout:` where version 2 relied on
  its 30 second default.
- Version 3 retries only errors that `Jido.Action.Error.retryable?/1` accepts.
  Set `details.retry: true` only when another attempt is safe.
- `base_delay_ms` and `max_delay_ms` both default to `0`. Set both to get a
  delay between attempts.
- `max_concurrency` defaults to `1`. Raise it to run independent Flow
  components in parallel.

Unknown options return a `Jido.Action.Error.ConfigurationError`. See
[Execution](execution.md) for the complete option list.

## Replace Async Handles

Version 3 removes the Jido async handle and the version 2 step-wise Execution
APIs. Replace `run_async`, `await`, `cancel`, `ready`, `step/1`, `wave`,
`continue`, and `result` calls on an Execution value with one of these paths:

- use `Jido.Exec.run/4` for immediate execution;
- use `Jido.Exec.compile/2` for a native `Runic.Workflow`;
- use `Jido.Exec.start/6` with a supervised `Runic.Runner` for managed work,
  and `Jido.Exec.step/2` for manual dispatch;
- use `Runic.Runner` to checkpoint and stop, `Jido.Exec.resume/4` to resume,
  and `Jido.Exec.result/1` to read a managed result.

For in-memory background work, call `Jido.Exec.run/4` from your own supervised
Task. Stop that Task to cancel the call. For work that must outlive the caller,
checkpoint, or resume, use `Jido.Exec.start/6` with a supervised
`Runic.Runner`. See [Managed Execution](managed-execution.md).

```elixir
task =
  Task.Supervisor.async_nolink(MyApp.TaskSupervisor, fn ->
    Jido.Exec.run(MyApp.Actions.CreateOrder, params, context, timeout: 5_000)
  end)

Task.await(task)
```

`run/4` stops its work when the calling process exits.

## Replace The Task Supervisor

Version 2 asks you to add `{Task.Supervisor, name: Jido.Action.TaskSupervisor}`
to your supervision tree.

### What You Need To Change

Remove that child. Version 3 starts `Jido.Exec.TaskSupervisor` in its own
application. `run/4` runs each call in one task under that supervisor. Pass
`task_supervisor:` to use a local Task Supervisor that you own:

```elixir
Jido.Exec.run(MyApp.Actions.CreateOrder, params, context,
  task_supervisor: MyApp.ExecSupervisor
)
```

Managed execution does not use this option. `start/6` rejects
`task_supervisor:`. Its Actions run under the Runner's own Task Supervisor.

## Replace Continuation Loops

Version 3 keeps control flow in Flow components, so Runic owns it. Use Choice
for routing, Iterate for bounded loops, and Dispatch for runtime target
selection. Only a Dispatch expander can return `{:continue, input, target}`.
Any other Action that returns it fails with an `ExecutionFailureError` whose
`details.reason` is `:unsupported_continuation`. See
[Dynamic Flows](dynamic-flows.md).

## Replace Jido Plan With Jido Flow

Skip this section if the application does not use `Jido.Plan`.

Version 3 removes `Jido.Plan`. `Jido.Flow` is a new graph model with explicit
input, context, result, and ordering references. There is no automatic
Plan-to-Flow conversion.

### What You Need To Change

Replace each reusable Plan with a Flow that states its data dependencies:

```elixir
# Version 2
plan =
  Jido.Plan.new()
  |> Jido.Plan.add(:fetch, MyApp.Actions.FetchOrder)
  |> Jido.Plan.add(:save, MyApp.Actions.SaveOrder, depends_on: :fetch)
```

```elixir
# Version 3
defmodule MyApp.Flows.FetchAndSaveOrder do
  use Jido.Flow, name: "fetch_and_save_order"

  flow do
    step "fetch",
      action: MyApp.Actions.FetchOrder,
      params: %{id: input(:id)}

    step "save",
      action: MyApp.Actions.SaveOrder,
      params: %{order: result("fetch")}

    output result("save")
  end
end
```

A result reference creates a dependency. Use `needs:` only for order that has
no data dependency. Pass runtime context to `Jido.Exec.run/4`; a Flow does not
store invocation context.

An Action failure inside a Flow keeps its `Jido.Action.Error` type, with the
component name in `details.node`. `Jido.Flow.Error` covers Flow definition,
reference, and coordination failures. See [Errors](errors.md). Test the new
Flow dependency order and final output against the old Plan behavior.

## Replace Action Chains And Closures

Version 3 removes `Jido.Exec.Chain` and `Jido.Exec.Closure`.

### What You Need To Change

Replace a reusable Chain with a Flow. State each step input explicitly with
`input/1`, `context/1`, `result/1`, and `select/2`. Version 3 does not perform
the version 2 implicit map merge between Actions.

Use `Enum.reduce_while/3` with `Jido.Exec.run/4` for a small dynamic sequence
that does not need a reusable graph.

Replace an Exec Closure with an ordinary function that calls
`Jido.Exec.run/4` with caller-owned context and options.

## Replace Catalogs, Tools, And Generators

Version 3 removes these version 2 parts:

- `Jido.Action.Catalog` and its Entry, Hit, and Query types
- `Jido.Action.Tool` and generated `to_tool/0`
- `Jido.Tools.*` and `Jido.Tools.ActionPlan`
- The Action, workflow, and install Mix tasks
- The version 2 JSON Schema bridge

### What You Need To Change

Move Action discovery, search, visibility, and policy to the application or to
the package that owns the integration. `Jido.Flow.Registry` is not an Action
Catalog and must not be used as one.

Move bundled tool use to application Actions or to the integration package.
Create Action and Flow modules as normal source files instead of calling the
removed Mix generators.

## Migrate Stored Version 2 Data Deliberately

Version 3 cannot decode a stored version 2 Plan, Instruction, or Action JSON
record as a version 3 Flow document.

### What You Need To Change

Add an application data migration when old records must remain usable. Decode
the old format with versioned application code, resolve each trusted target,
and build a new Instruction or Flow.

Do not send version 2 data directly to `Jido.Flow.Codec.decode/2`. Add a format
version to application-owned stored data and test the migration through real
JSON bytes.

For durable execution, store two values: the Flow definition through
`Jido.Flow.Codec`, and runtime progress through a Runic Store. Do not store a
compiled workflow or add checkpoint fields to Instructions.

## Upgrading From Earlier v3 Betas

The `Jido.Exec` rebuild on Runic replaced the version 3 execution API that
shipped through `3.0.0-beta.12`. Replace each removed API:

| Removed | Replacement |
| --- | --- |
| `run_async/4`, `await/1,2`, `cancel/1`, `handle_message/2` | `run/4` inside your own supervised Task, or `start/6` for managed work. See [Replace Async Handles](#replace-async-handles). |
| `remaining_time/1` and `context.__jido_exec__` | None. `timeout:` applies to each attempt. Pass your own deadline in context when an Action needs one. |
| `start/4`, `ready/1`, `status/1`, `step/1`, `step/2` with a Work token, `wave/1`, `continue/1`, `result/1`, `native/1`, `Jido.Exec.Work`, and `%Jido.Exec.Execution{}` | `start/6` with `dispatch_mode: :manual`, then `Jido.Exec.step(runner, execution_id)`. Read state and results through `Runic.Runner`. See [Managed Execution](managed-execution.md). |
| `max_continuations:` | None. Only a Dispatch expander can continue. |
| `{:continue, input, target}` from a root Action | A Dispatch component. Other Actions fail with `:unsupported_continuation`. |
| `invocation:` and `Jido.Exec.Invocation` (development builds) | None. Keep receipts and replay in your application. |
| `Jido.Flow.compile/1`, `compile!/1`, and `validate_executable/1` | `Jido.Exec.compile/2`. It checks targets and returns a `%Runic.Workflow{}`. |
| `Jido.Executable` | `Jido.Instruction.resolve/3` and `Jido.Instruction.validate/1` |
| `Jido.Exec.Flow.*` and `Jido.Flow.Component` | None. These were internal. Use `Jido.Exec` and the public Runic APIs. |

Check these behavior changes:

- `timeout:` applies to each attempt of each runnable, including internal Flow
  nodes. There is no whole-call timeout.
- `max_concurrency` for `run/4` now defaults to `1`, not `8`. `start/6`
  defaults to `System.schedulers_online()`.
- An Action no longer runs in its own fresh Task under a private supervisor.
  `run/4` runs the whole call in one task under `Jido.Exec.TaskSupervisor`.
- `max_attempts`, `backoff`, `base_delay_ms`, and `max_delay_ms` are new retry
  options. See [Replace The Exec Options](#replace-the-exec-options).
- Flows now return the effect lists of all their components. See
  [Outputs And Effects](action-effects.livemd).
- `Jido.Exec.effect_id/4` derives a stable deduplication key for one effect
  in a managed result.
- Runic does not persist run context. After a resume, Actions receive an empty
  context. Put data that must survive a restart in params.

## Version 2 To Version 3 Migration Checklist

1. Change the dependency to `jido_action` `3.0.0-beta.12`.
2. Add direct dependencies that application code used through version 2.
3. Remove unsupported Action options and convert NimbleOptions schemas to
   static, map-shaped Zoi schemas.
4. Declare the Zoi unknown-key policy for nested data.
5. Keep only `on_before_validate_params/1`; move work from the five removed
   Action hooks.
6. Replace generated Action metadata, JSON, and AI tool functions.
7. Wrap each third success element in a list of effect requests.
8. Replace Instruction fields, shorthand forms, and allowlist calls.
9. Map Exec options: set `timeout:` explicitly, convert `max_retries` to
   `max_attempts`, and remove `log_level:` and `:jido_action` config defaults.
10. Replace async handles with your own Task or managed execution.
11. Remove the `Jido.Action.TaskSupervisor` child.
12. Replace continuation loops with Choice, Iterate, or Dispatch.
13. Move rollback and compensation to their owning application service.
14. Replace Plans, Chains, and Closures where the application uses them.
15. Replace catalog, bundled-tool, and generator integrations.
16. Migrate stored version 2 data with an explicit versioned data migration.
17. Compile with warnings as errors.
18. Test Action input, output, error, timeout, retry, and process-exit
    boundaries.
19. Test each replacement Flow for data dependencies, order, and final output.

See [Actions](actions.md), [Instructions](instructions.md),
[Execution](execution.md), [Errors](errors.md), [Flows](flows.md), and
[Store Flows As JSON](flow-storage.md) for the version 3 contracts.
