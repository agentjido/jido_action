# Upgrade

## Upgrading From v2 To v3

This guide contains the breaking changes between the published `v2.3.2`
release and `v3.0.0-beta.3`. It gives the changes that you must make in your
application.

The guide does not use an unpublished Flow design as its version 2 baseline.
Version 2 has `Jido.Action`, `Jido.Instruction`, `Jido.Exec`, `Jido.Plan`,
Action catalogs, Action tools, and bundled tool modules. It does not have
`Jido.Flow`.

Version 3 keeps Actions as executable units. It makes `Jido.Exec` a smaller
execution boundary and adds Flow as a new data-first graph model. A version 2
Plan is not an old Flow value. There is no automatic Plan-to-Flow conversion.

Upgrade one area at a time. Compile and test the application after each area.

### Dependency Changes

Version `3.0.0-beta.3` requires Elixir 1.18 or later.

#### What You Need To Change

Change the dependency in `mix.exs`:

```elixir
def deps do
  [
    {:jido_action, "~> 3.0.0-beta.3"}
  ]
end
```

Version 3 no longer supplies several dependencies that version 2 used for
catalogs, tools, schemas, and examples. Add a direct dependency to your
application if your code still uses Jason, NimbleOptions, Req, Lua,
Multigraph, or Igniter.

### Action Definitions Use A Smaller Contract

Version 2 accepts metadata, compensation, NimbleOptions schemas, and Zoi
schemas in `use Jido.Action`. Version 3 accepts only `name`, `description`,
`schema`, and `output_schema`.

When supplied, `schema` and `output_schema` must be map-shaped Zoi schemas.
The empty list means that no field schema is declared. The Action boundary
still requires a map for normal input and output.

#### What You Need To Change

Replace version 2 Action options and NimbleOptions schemas:

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

Use the version 3 options and Zoi schemas:

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

Keep metadata such as category, tags, and version in application modules or
plain module functions. These values are not part of the version 3 Action
contract.

Version 3 rejects anonymous functions, lazy schemas, process values, and
other runtime-only values in an Action schema. Use a named MFA effect for a
Zoi refinement or transform:

```elixir
schema:
  Zoi.object(%{
    customer_id:
      Zoi.string()
      |> Zoi.refine({__MODULE__, :not_blank, []})
  })
```

A direct object or struct schema preserves unknown keys at the Action root.
Nested and wrapped schemas use the Zoi unknown-key policy that you declare.
Set `unrecognized_keys: :preserve` on each nested object that must keep its
unknown keys:

```elixir
Zoi.object(%{
  customer:
    Zoi.object(
      %{name: Zoi.string()},
      unrecognized_keys: :preserve
    )
})
```

### Most Action Lifecycle Hooks Have Been Removed

Version 3 keeps `on_before_validate_params/1`. It runs before the input Zoi
schema and can prepare raw input that Zoi cannot parse directly.

Version 3 removes these other version 2 callbacks:

- `on_after_validate_params/1`
- `on_before_validate_output/1`
- `on_after_validate_output/1`
- `on_after_run/1`
- `on_error/4`

#### What You Need To Change

Prefer Zoi coercion, defaults, enums, and refinements for data validation and
transformation. Keep `on_before_validate_params/1` only when deterministic
input preparation must happen before Zoi can parse the value.

Put Action-owned authentication, authorization, and secret lookup in `run/2`.
These controls can also stay in a trusted caller or higher-level runtime. Put
retry, rollback, and compensation policy in the caller or runtime.

### Generated Action Metadata And Tool Calls Have Been Removed

Version 3 does not generate these version 2 functions:

- `category/0`, `tags/0`, and `vsn/0`
- `to_json/0` and `to_tool/0`
- `__action_metadata__/0`

`Jido.Exec` no longer adds `:action_metadata` to the Action context.

#### What You Need To Change

Pass needed data in the context, or read `name/0` and `description/0` from the
Action module.

Build AI tool descriptions in the package that owns the AI integration. That
adapter can read `name/0`, `description/0`, and `schema/0`. It can call
`Jido.Exec.run/4` to run the Action.

### Actions Can Continue To Another Executable

The common version 2 result shapes stay valid:

```elixir
{:ok, result_map}
{:ok, result_map, extras}
{:error, reason}
{:error, reason, extras}
```

Version 3 also supplies `Jido.Action.Output` for a successful raw, batch,
stream, or opaque value. Direct Action and Instruction calls preserve extras.
A Flow node uses only the Action result or error reason.

An Action can also select the next Action or Flow in the same complete Exec
call:

```elixir
{:continue, next_input, next_target}
```

The input must be a map. The target must be an Action module, Flow module, or
runtime Flow value. The current context passes to the target. The final target
owns output validation, extras, and the final result.

Inside a Flow, only the expander of a terminal `Jido.Flow.Dispatch` can return
a continuation. Other Flow nodes reject it. Step-wise execution and Subflow
use reject a Flow that contains Dispatch.

#### What You Need To Change

You do not need to change Actions that use a common version 2 result shape.
Use a continuation only when an Action must select the next executable.

Set a finite continuation budget and timeout for executable loops:

```elixir
Jido.Exec.run(MyApp.Reason, input, context,
  max_continuations: 12,
  timeout: 30_000
)
```

`max_continuations` defaults to `256`. The complete-call timeout and the
continuation budget apply to the complete Action and Flow chain.

See [Continue to Another Executable](continuations.md) for the Dispatch rules
and an LLM tool-loop example.

### `Jido.Instruction.action` Is Now `target`

The version 2 Instruction stores Action-specific data:

```elixir
Jido.Instruction.new!(
  id: "send-1",
  action: MyApp.Actions.SendEmail,
  params: %{to: "user@example.com"},
  context: %{tenant_id: "tenant-1"},
  opts: [timeout: 5_000]
)
```

The version 3 Instruction stores one executable call:

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

#### What You Need To Change

Apply these field changes:

| Version 2 field | Version 3 field or location |
| --- | --- |
| `action` | `target` |
| `id` | Caller data, or `metadata` when it is descriptive |
| `params` | `params` |
| `context` | `context` |
| `opts` | Options passed to `Jido.Exec.run/4` |

A version 3 target can be an Action module, Flow module, or runtime Flow
value. The constructor resolves the target when it builds the Instruction.

Version 3 has temporary migration shims for `action:` and `opts`. The Action
shim confirms that the target is an Action, emits a runtime warning, and
normalizes it to `target`. The options shim forwards `timeout` and `jido`. It
reports removed or unknown version 2 settings.

The shims do not restore `id`, symbolic Action names, or the removed
normalization functions. A typed `flow:` input also normalizes to `target`,
but it does not emit the version 2 migration warning. Use `target:` as the
canonical version 3 form.

See [Migration Shims](migration-shims.md) for all shim behavior.

Version 3 removes `normalize/3`, `normalize_single/3`,
`validate_allowed_actions/2`, and the module and tuple shorthand formats.
Build each Instruction with `new/1` or `new!/1`. Use an application allowlist
before construction when a target comes from another trust boundary.

### Execution Policy Is Smaller

`Jido.Exec.run/4` stays as the normal execution entry point. Its policy is
smaller and some defaults are different.

| Version 2 behavior | Version 3 behavior |
| --- | --- |
| `run/1` or `run/4` runs an Instruction or Action | `run/4` runs an Action, Instruction, Flow module, or Flow value |
| Default timeout is 30 seconds | Default timeout is `:infinity` |
| Automatic retry and backoff | No automatic retry |
| Action compensation callback | No compensation policy |
| `run_async/4`, `await/1`, `await/2`, and `cancel/1` | Owner-bound, in-memory execution; `handle_message/2` adds OTP callback handling |
| Per-call log and telemetry modes | Removed |
| Context propagator options | Removed |
| `jido:` instance routing | Kept |
| Flow `async:` option | Removed; use `max_concurrency` |

All run-to-completion targets accept `timeout`, `jido`,
`max_continuations`, and `max_concurrency`. The limits apply to the complete
executable chain. `max_concurrency` defaults to `8`. Use `1` for serial Flow
scheduling. A value greater than `1` lets independent graph work run at the
same time. An Action does not use this limit itself, but it can continue to a
Flow.

#### What You Need To Change

Remove the Flow `async:` option. Select serial or concurrent Flow work only
with `max_concurrency`:

```elixir
Jido.Exec.run(MyApp.Flows.Import, input, context,
  max_concurrency: 4
)
```

Use the Exec async API for one run-to-completion Action, Instruction, or Flow:

```elixir
handle =
  Jido.Exec.run_async(
    MyApp.Actions.CreateOrder,
    params,
    context,
    timeout: 5_000
  )

Jido.Exec.await(handle)
```

The process that creates the handle owns it. That process must await, handle,
or cancel it. `await/1` has a 5-second wait limit. An `await/2` timeout cancels
the execution. The `timeout:` run option is a separate complete-call limit.

Use `handle_message/2` to consume a result in an OTP callback without a
blocking wait. Await, message handling, and cancellation are alternative
one-shot terminal operations.

This async API does not make a paused step-wise Execution asynchronous.

Errors can still state if another attempt is safe. `Jido.Exec` does not act on
that state. The caller must own the attempt count, delay, deadline, and
idempotency rules.

### Package Runtime Configuration Has Been Removed

Version 2 reads package configuration such as:

```elixir
config :jido_action,
  default_timeout: 30_000,
  default_max_retries: 3,
  default_backoff: 500,
  default_log_level: :info
```

Version 3 does not read these execution defaults.

#### What You Need To Change

Delete this configuration, or move it to the application that calls Exec.
Pass the selected policy to `run/4`:

```elixir
timeout = Application.fetch_env!(:my_app, :action_timeout)

Jido.Exec.run(action, params, context,
  timeout: timeout,
  jido: MyApp.Jido
)
```

Unknown version 3 run options return an error. Remove `max_retries`,
`backoff`, `log_level`, `telemetry`, `context_propagators`,
`context_propagator_failure_mode`, and `error_normalization` from Exec calls.

### `Jido.Plan` Has Been Replaced By `Jido.Flow`

`Jido.Plan` in version 2 stores a DAG of Instructions and dependency names.
`Jido.Flow` in version 3 is a new executable graph with explicit data
references and one required output.

#### What You Need To Change

For a static graph, replace a Plan with a Flow module:

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

The result reference creates the `fetch` to `save` dependency. Use `after:`
only when you need order without a data reference:

```elixir
step "audit",
  action: MyApp.Actions.AuditOrder,
  params: %{id: input(:id)},
  after: ["save"]
```

Use `Jido.Flow.Builder` when application code builds a graph at runtime. Use
direct Flow and component constructors when the application already has the
canonical data.

A Flow does not store runtime context. Pass context to `Jido.Exec.run/4`, or
store invocation context in a `Jido.Instruction`.

### Action Chains And Closures Have Been Removed

The version 2 `Jido.Exec.Chain` passes accumulated map data through a
sequential list of Actions. It merges each Action result into the parameters
for the next Action. Version 3 does not do this implicit merge.

Version 3 also removes `Jido.Exec.Closure`.

#### What You Need To Change

For a reusable graph, use a Flow. State the input for each step with
`result/1` and `select/2`. This makes the dependency and data contract
visible.

Use `Enum.reduce_while/3` with `Jido.Exec.run/4` when you need only a dynamic
sequential loop and do not need a reusable graph.

Replace an Exec Closure with an ordinary function that calls
`Jido.Exec.run/4` with the context and options that it owns.

### Catalogs, Tools, And Generators Have Been Removed

Version 3 removes these version 2 parts:

- `Jido.Action.Catalog` and its Entry, Hit, and Query types
- `Jido.Action.Tool` and generated `to_tool/0`
- `Jido.Tools.*` and `Jido.Tools.ActionPlan`
- `Jido.Plan`
- The Action, workflow, and install Mix tasks
- The JSON Schema bridge and internal Action utility modules

#### What You Need To Change

Keep discovery, search, visibility, and AI tool policy in the application or
package that owns those concerns. There is no one-for-one replacement for the
Action Catalog.

`Jido.Flow.Registry` is not an Action Catalog. It is a trusted lookup table
for stable identifiers in stored Flow documents. Use it only with
`Jido.Flow.Codec`.

Move bundled version 2 tool use to application Actions or to the package that
owns the integration. Create Action and Flow modules as normal source files.
The old Mix generators are not part of version 3.

### Stored Flow Data Is A New Format

Version 2 has no stored Jido Flow format. Version 2 Plan maps, Instructions,
Action JSON, and development-spike records are not valid version 3 Flow data.

#### What You Need To Change

Build a canonical version 3 Flow. Then encode it with a trusted Registry:

```elixir
{:ok, stored_map} = Jido.Flow.Codec.encode(flow, registry)
json = JSON.encode!(stored_map)

{:ok, restored_flow} =
  json
  |> JSON.decode!()
  |> Jido.Flow.Codec.decode(registry)
```

Use `Codec.encode/1` only for temporary data within one application version:

```elixir
{:ok, stored_map, temporary_registry} = Jido.Flow.Codec.encode(flow)
```

Keep the returned Registry for decoding. Generated identifiers are not stable
across Flow, module, or schema changes. Do not use them for durable storage.

Use `Jido.Flow.Codec.diagnose/2` when an editor needs all independent document
and graph errors in one result.

### Error Handling Is Stricter

The concrete `Jido.Action.Error` exception names stay available. Existing
matches on `InvalidInputError`, `ExecutionFailureError`, `TimeoutError`,
`ConfigurationError`, and `InternalError` can often stay.

Version 3 changes these rules:

- Errors are not retryable unless a concrete execution or timeout error has
  `details.retry: true`.
- An unknown value becomes a conservative Action execution error.
- `Jido.Exec` does not retry a retryable error.
- Flow definition and execution errors use `Jido.Flow.Error`.

#### What You Need To Change

Review code that matches errors or assumes automatic retry. Put retry policy
in the caller.

Use `Jido.Action.Error.to_map/1` or `Jido.Flow.Error.to_map/1` when an HTTP,
JSON, or UI boundary needs stable data.

### The Default Task Supervisor Name Has Changed

The default version 2 Task Supervisor is `Jido.Action.TaskSupervisor`. The
default version 3 Task Supervisor is `Jido.Exec.TaskSupervisor`. The package
application starts it.

#### What You Need To Change

Update code that refers to the old global supervisor by name.

Instance routing keeps the same convention. `jido: MyApp.Jido` selects
`MyApp.Jido.TaskSupervisor`. The instance must start that supervisor. Version
3 returns a structured error when it is not running. It does not use the
global supervisor as a fallback.

Higher-level runtimes can use `Jido.Exec.task_supervisor_name/1` when they
build the instance supervision tree.

## Upgrade Checklist

1. Change the dependency to `jido_action` `3.0.0-beta.3` and require Elixir
   1.18 or later.
2. Remove unsupported Action options and callbacks.
3. Convert each NimbleOptions Action schema to a static Zoi object schema.
4. Set the Zoi unknown-key policy on nested objects that must preserve unknown
   keys.
5. Replace Instruction `action`, `id`, and `opts` fields.
6. Remove version 2 Instruction shorthand normalization.
7. Move timeout defaults, retry, compensation, and durable cancellation to
   the caller.
8. Remove the Flow `async:` option and select `max_concurrency` directly.
9. Replace Plans and reusable Chains with explicit Flows where this is useful.
10. Replace tool, catalog, and bundled-tool integrations outside this package.
11. Update global supervisor names.
12. Compile with warnings as errors and remove all migration-shim warnings.
13. Test Action input, output, error, timeout, and process-exit boundaries.
14. Test each Flow through complete and step-wise execution when you use both
    APIs.
15. Round-trip stored Flows through real JSON bytes and the trusted Registry.

See [Actions](actions.md), [Instructions](instructions.md),
[Direct Construction And Builder](flow-builder.md),
[Execution Contract](execution.md), and [Store Flows As JSON](flow-storage.md)
for the version 3 contracts.
