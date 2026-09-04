# Version 2 To Version 3 Migration Guide

This guide explains how to migrate an application from the published
`jido_action` version `2.3.2` API to version `3.0.0-beta.6`.

This guide covers only version 2 to version 3 changes. Each section starts
with version 2 code that no longer has the same contract. It then gives the
version 3 replacement. New version 3 features that do not require a change to
version 2 code are outside the scope of this guide.

Upgrade one area at a time. Compile and test the application after each area.

## Update The Dependency

Change the package version in `mix.exs`:

```elixir
def deps do
  [
    {:jido_action, "~> 3.0.0-beta.6"}
  ]
end
```

Version 3 no longer supplies several dependencies used by version 2 catalogs,
tools, schemas, and examples.

### What You Need To Change

Add a direct dependency if your application code still uses Jason,
NimbleOptions, Req, Lua, Multigraph, or Igniter. Do not depend on
`jido_action` to supply these packages.

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
When present, each schema must be a map-shaped Zoi schema. An empty list still
means that the Action has no declared field schema.

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

Version 2 can accept schema values that contain anonymous functions, lazy
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

Version 3 preserves unknown keys at a direct Action object or struct root.
Nested and wrapped schemas use their declared Zoi unknown-key policy.

Version 2 code can therefore lose or reject nested keys after the upgrade if
it relied on the old open behavior.

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
- `to_json/0` and `to_tool/0`
- `__action_metadata__/0`

`Jido.Exec` also stops adding `:action_metadata` to the Action context.

### What You Need To Change

Replace calls to `category/0`, `tags/0`, and `vsn/0` with application-owned
metadata. Pass required invocation data in the Action context.

Move AI tool conversion to the package that owns the AI integration. That
adapter can read `name/0`, `description/0`, and `schema/0`, then call
`Jido.Exec.run/4`.

An Action does not need a second tool specification. Its name, description,
and input schema contain the data that an integration needs to create a tool.
ReqLLM owns the generic Tool type and provider-specific tool formats. Jido AI
owns the adapter from a Jido Action to a ReqLLM Tool and owns execution of the
selected Action.

If you use Jido AI, replace the generated function with the Jido AI adapter:

```elixir
# Version 2
tool = MyApp.Actions.Search.to_tool()

# Version 3
tool = Jido.AI.ToolAdapter.from_action(MyApp.Actions.Search)
```

Use a Jido AI release that supports `jido_action` version 3. An adapter for
version 3 can pass the Action Zoi schema to ReqLLM. It must not depend on the
removed `Jido.Action.Schema` or `Jido.Action.Tool` modules.

Replace Action JSON with an application-owned format. An Action module is not
a stored version 3 document.

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

A version 3 Instruction stores one executable target. Execution options are
passed to `Jido.Exec`:

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

Version 3 temporarily accepts `action:` and `opts` as migration shims. These
paths emit warnings. Replace them before the upgrade is complete. The shim
for `opts` forwards `timeout` and `jido`; it does not restore removed version
2 execution policy.

See [Migration Shims](migration-shims.md) for the exact warning and error
behavior.

## Replace Instruction Shorthand And Allowlists

Version 3 removes these version 2 functions and input forms:

- `normalize/3` and `normalize_single/3`
- The version 2 list-return behavior of `normalize!/3`
- Module, tuple, and list shorthand
- `validate_allowed_actions/2`

Version 3 has a different `normalize!/3` contract for one target or
Instruction. It does not replace the version 2 list normalizer.

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

## Set An Explicit Execution Timeout

The version 2 `Jido.Exec` default timeout is 30 seconds. The version 3 default
is `:infinity`.

### What You Need To Change

If your application depends on the version 2 limit, pass it explicitly:

```elixir
Jido.Exec.run(action, params, context, timeout: 30_000)
```

Review each call that relied on the package default. Select a timeout from the
application policy for that operation.

## Move Retry And Compensation Policy Out Of Jido Exec

Version 2 can retry Actions with backoff and can call `on_error/4` when
compensation is enabled. Version 3 does neither.

An error can still state whether another attempt can be safe. `Jido.Exec` does
not act on that value.

### What You Need To Change

Move attempt count, backoff, deadline, idempotency, rollback, and compensation
to the caller or to a higher-level runtime. Do not copy automatic retry into
`run/2` unless the Action itself owns the complete idempotent operation.

## Remove Unsupported Exec Options And Package Configuration

Version 3 removes these version 2 Exec options:

- `max_retries`
- `backoff`
- `log_level`
- `telemetry`
- `context_propagators`
- `context_propagator_failure_mode`
- `error_normalization`

Version 3 also stops reading package defaults such as:

```elixir
config :jido_action,
  default_timeout: 30_000,
  default_max_retries: 3,
  default_backoff: 500,
  default_log_level: :info
```

### What You Need To Change

Remove unsupported options from every Exec call and from each Instruction.
Unknown version 3 run options return an error.

Move required configuration to your application. Read it before the call and
pass supported policy directly:

```elixir
timeout = Application.fetch_env!(:my_app, :action_timeout)

Jido.Exec.run(action, params, context,
  timeout: timeout,
  jido: MyApp.Jido
)
```

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

A result reference creates a dependency. Use `after:` only for order that has
no data dependency. Pass runtime context to `Jido.Exec.run/4`; a Flow does not
store invocation context.

Update error handling for Flow calls to use `Jido.Flow.Error`. Test the new
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

Version 3 cannot decode a stored version 2 Plan, Instruction, Action JSON, or
development-spike record as a version 3 Flow document.

### What You Need To Change

Add an application data migration when old records must remain usable. Decode
the old format with versioned application code, resolve each trusted target,
and build a new Instruction or Flow.

Do not send version 2 data directly to `Jido.Flow.Codec.decode/2`. Add a format
version to application-owned stored data and test the migration through real
JSON bytes.

## Update The Default Task Supervisor Name

Version 2 uses `Jido.Action.TaskSupervisor` as its default Task Supervisor.
Version 3 uses `Jido.Exec.TaskSupervisor`.

### What You Need To Change

Replace direct references to the old global supervisor name.

Instance routing keeps `MyApp.Jido.TaskSupervisor` for
`jido: MyApp.Jido`. The selected instance must start that supervisor. Version
3 returns an error when the instance supervisor is not running; it does not
fall back to the global supervisor.

## Version 2 To Version 3 Migration Checklist

1. Change the dependency to `jido_action` `3.0.0-beta.6`.
2. Add direct dependencies that application code used through version 2.
3. Remove unsupported Action options and convert NimbleOptions schemas to
   static, map-shaped Zoi schemas.
4. Declare the Zoi unknown-key policy for nested data.
5. Keep only `on_before_validate_params/1`; move work from the five removed
   Action hooks.
6. Replace generated Action metadata, JSON, and AI tool functions.
7. Replace Instruction fields, shorthand forms, and allowlist calls.
8. Set explicit Exec timeouts where the application relied on 30 seconds.
9. Move retry, backoff, rollback, and compensation to their owning runtime.
10. Remove unsupported Exec options and `:jido_action` runtime defaults.
11. Replace Plans, Chains, and Closures where the application uses them.
12. Replace catalog, bundled-tool, and generator integrations.
13. Migrate stored version 2 data with an explicit versioned data migration.
14. Replace direct references to `Jido.Action.TaskSupervisor`.
15. Compile with warnings as errors and remove all migration-shim warnings.
16. Test Action input, output, error, timeout, and process-exit boundaries.
17. Test each replacement Flow for data dependencies, order, and final output.

See [Actions](actions.md), [Instructions](instructions.md),
[Execution](execution.md), [Flows](flows.md), and
[Store Flows As JSON](flow-storage.md) for the version 3 contracts.
