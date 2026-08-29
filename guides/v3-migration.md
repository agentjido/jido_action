# Upgrade From v2 To v3

This guide compares the published `v2.3.2` release with the v3 API introduced
in `v3.0.0-beta.1` and refined in `v3.0.0-beta.2`. It does not use an earlier,
unpublished Flow design as its baseline.

Version 2 has `Jido.Action`, `Jido.Instruction`, `Jido.Exec`, `Jido.Plan`,
Action catalogs, Action tools, and bundled tool modules. Version 2 does not
have `Jido.Flow`.

Version 3 keeps Actions as executable units. It makes `Jido.Exec` a smaller
execution boundary and adds Flow as a new data-first graph model. A v2 Plan is
not an old Flow value, and there is no automatic Plan-to-Flow conversion.

## Update The Dependency

The published `v3.0.0-beta.2` package requires Elixir 1.18 or later.

```elixir
def deps do
  [
    {:jido_action, "~> 3.0.0-beta.2"}
  ]
end
```

Version 3 no longer supplies several dependencies that v2 used for catalogs,
tools, schemas, and examples. Add a direct dependency in your application if
you still use Jason, NimbleOptions, Req, Lua, Multigraph, or Igniter for your
own code.

## Migrate Actions

The Action callback stays `run/2`. The Action input and normal output stay
map-shaped. The Action definition is smaller.

### Replace Action Options

Version 2 accepts metadata, compensation, NimbleOptions schemas, and Zoi
schemas:

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
When supplied, both schemas must be map-shaped Zoi schemas. The empty list
still means that no schema is declared.

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

Use application modules or plain module functions for metadata such as
category, tags, and version. These values are no longer part of the Action
contract.

Version 3 rejects anonymous functions, lazy schemas, process values, and other
runtime-only values in an Action schema. Use named MFA effects when a Zoi
schema needs a refinement or transform.

```elixir
schema:
  Zoi.object(%{
    customer_id:
      Zoi.string()
      |> Zoi.refine({__MODULE__, :not_blank, []})
  })
```

### Remove Action Lifecycle Hooks

Version 3 removes these v2 callbacks:

- `on_before_validate_params/1`;
- `on_after_validate_params/1`;
- `on_before_validate_output/1`;
- `on_after_validate_output/1`;
- `on_after_run/1`; and
- `on_error/4`.

Put data validation and transformation in the Zoi schemas. Put work that is
part of the Action in `run/2`. Put retry, rollback, and compensation policy in
the caller or in a higher-level runtime.

### Remove Generated Metadata And Tool Calls

Version 3 does not generate these v2 functions:

- `category/0`, `tags/0`, and `vsn/0`;
- `to_json/0` and `to_tool/0`; and
- `__action_metadata__/0`.

`Jido.Exec` no longer adds `:action_metadata` to the Action context. Pass the
needed data in context, or read `name/0` and `description/0` from the Action
module.

Build AI tool descriptions in the package that owns the AI integration. That
adapter can read `name/0`, `description/0`, and `schema/0`, and it can call
`Jido.Exec.run/4`.

### Keep The Supported Callback Results

The common v2 return shapes still work:

```elixir
{:ok, result_map}
{:ok, result_map, extras}
{:error, reason}
{:error, reason, extras}
```

Version 3 also provides `Jido.Action.Output` for a successful raw, batch,
stream, or opaque value. Direct Action and Action Instruction calls preserve
extras. A Flow node uses only the Action result or error reason.

## Migrate Instructions

The v2 Instruction stores Action-specific data:

```elixir
Jido.Instruction.new!(
  id: "send-1",
  action: MyApp.Actions.SendEmail,
  params: %{to: "user@example.com"},
  context: %{tenant_id: "tenant-1"},
  opts: [timeout: 5_000]
)
```

The v3 Instruction stores one executable call:

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

Apply these field changes:

| v2 field | v3 field or location |
| --- | --- |
| `action` | `target` |
| `id` | caller data, or `metadata` when it is descriptive |
| `params` | `params` |
| `context` | `context` |
| `opts` | options passed to `Jido.Exec.run/4` |

A v3 target can be an Action module, a Flow module, or a runtime Flow value.
The constructor resolves the target when it builds the Instruction.

As a migration aid, version 3 accepts `action:` in `new/1`, `new!/1`, and raw
Instruction struct literals. It confirms that the value is an Action, emits a
runtime warning, and normalizes the value to `target`. This lets old code
compile so tests and migration tools can find and replace each use.

```elixir
legacy = %Jido.Instruction{action: MyApp.Actions.SendEmail, params: params}
{:ok, result} = Jido.Exec.run(legacy)
```

The compatibility path does not restore `id`, symbolic Action names, or the
removed normalization functions. It accepts deprecated `opts` so old struct
literals compile. Exec warns, forwards `timeout` and `jido`, and leaves out
known version 2 settings that version 3 removed. Unknown settings return an
error. A typed `flow:` construction input is also accepted and normalized to
`target`, but it does not emit the version 2 migration warning. Use `target:`
for the canonical v3 form.

See [Migration Shims](migration-shims.md) for the package compatibility policy,
warning behavior, and option results.

Version 3 removes `normalize/3`, `normalize_single/3`,
`validate_allowed_actions/2`, and the module and tuple shorthand formats.
Build each Instruction explicitly with `new/1` or `new!/1`. Use your own
allowlist before construction when the target comes from another trust
boundary.

## Migrate Execution Policy

`Jido.Exec.run/4` stays as the normal execution entry point. Its policy is
smaller and its defaults are different.

| v2 behavior | v3 behavior |
| --- | --- |
| `run/1` or `run/4` runs an Instruction or Action | `run/4` runs an Action, Instruction, Flow module, or Flow value |
| default timeout is 30 seconds | default timeout is `:infinity` |
| automatic retry and backoff | no automatic retry |
| Action compensation callback | no compensation policy |
| `run_async/4`, `await/1`, `await/2`, and `cancel/1` | kept for owner-bound, in-memory execution; `handle_message/2` adds OTP callback handling |
| per-call log and telemetry modes | removed |
| context propagator options | removed |
| `jido:` instance routing | kept |

All run-to-completion targets accept `timeout`, `jido`, `max_continuations`,
and `max_concurrency`. The continuation and concurrency limits apply to the
complete executable chain. `max_concurrency` defaults to `8`. Use `1` for
serial Flow scheduling. A value greater than `1` lets independent graph work
run at the same time. An Action does not use this limit itself, but it can
continue to a Flow. The Flow `async:` option was removed.

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

The creating process owns the handle and must await or cancel it. An await
timeout cancels the execution. The `timeout:` run option stays a separate
complete-call limit. This API does not make a paused step-wise Execution
asynchronous.

Errors can still state whether another attempt is safe. `Jido.Exec` does not
act on that state. The caller must own the attempt count, delay, deadline, and
idempotency rules.

## Replace Runtime Configuration

Version 2 reads package configuration such as:

```elixir
config :jido_action,
  default_timeout: 30_000,
  default_max_retries: 3,
  default_backoff: 500,
  default_log_level: :info
```

Version 3 does not read these execution defaults. Delete this configuration,
or move it to the application that calls Exec. Pass the selected policy to
`run/4`.

```elixir
timeout = Application.fetch_env!(:my_app, :action_timeout)

Jido.Exec.run(action, params, context,
  timeout: timeout,
  jido: MyApp.Jido
)
```

Unknown v3 run options return an error. Remove `max_retries`, `backoff`,
`log_level`, `telemetry`, `context_propagators`,
`context_propagator_failure_mode`, and `error_normalization` from calls to
Exec.

## Replace Plans With Flows When You Need Execution

`Jido.Plan` in v2 stores a DAG of Instructions and dependency names.
`Jido.Flow` in v3 is a new executable graph with explicit data references and
one required output.

For a static graph, replace a Plan with a Flow module.

```elixir
# v2
plan =
  Jido.Plan.new()
  |> Jido.Plan.add(:fetch, MyApp.Actions.FetchOrder)
  |> Jido.Plan.add(:save, MyApp.Actions.SaveOrder, depends_on: :fetch)
```

```elixir
# v3
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
only when you need ordering without a data reference.

```elixir
step "audit",
  action: MyApp.Actions.AuditOrder,
  params: %{id: input(:id)},
  after: ["save"]
```

Use `Jido.Flow.Builder` when application code builds the graph at runtime. Use
direct Flow and component constructors when the application already has the
canonical data.

A Flow does not store runtime context. Pass context to `Jido.Exec.run/4` or
store invocation context in a `Jido.Instruction`.

## Replace Action Chains Deliberately

The v2 `Jido.Exec.Chain` passes accumulated map data through a sequential list
of Actions. It merges each Action result into the parameters for the next
Action.

Version 3 does not do this implicit merge. A Flow must state the input for each
step. Use `result/1` and `select/2` to define the data path. This makes the
dependency and data contract visible.

Use an ordinary `Enum.reduce_while/3` with `Jido.Exec.run/4` when you only need
a dynamic sequential loop and do not need a reusable graph.

Version 3 also removes `Jido.Exec.Closure`. Use an ordinary function that calls
`Jido.Exec.run/4` with the context and options that it owns.

## Replace Catalogs, Tools, And Generators

Version 3 removes these v2 parts:

- `Jido.Action.Catalog` and its Entry, Hit, and Query types;
- `Jido.Action.Tool` and generated `to_tool/0`;
- `Jido.Tools.*` and `Jido.Tools.ActionPlan`;
- `Jido.Plan`;
- the Action, workflow, and install Mix tasks; and
- the JSON Schema bridge and internal Action utility modules.

There is no one-for-one replacement for the Action Catalog. Keep discovery,
search, visibility, and AI tool policy in the application or package that owns
those concerns.

`Jido.Flow.Registry` is not an Action Catalog. It is a trusted lookup table for
stable identifiers in stored Flow documents. Use it only with
`Jido.Flow.Codec`.

Move bundled v2 tool use to application Actions or to the package that now owns
that integration. Create new Action and Flow modules as normal source files;
the old Mix generators are not part of v3.

## Treat Flow Storage As A New Format

Version 2 has no stored Jido Flow format. Do not send v2 Plan maps,
Instructions, Action JSON, or development-spike records to
`Jido.Flow.Codec.decode/2`.

Build a canonical v3 Flow first. Then encode it with a trusted Registry.

```elixir
{:ok, stored_map} = Jido.Flow.Codec.encode(flow, registry)
json = JSON.encode!(stored_map)

{:ok, restored_flow} =
  json
  |> JSON.decode!()
  |> Jido.Flow.Codec.decode(registry)
```

Post-beta source on `release/v3` adds `Codec.encode/1` for temporary data
within one application version. It can return the stored map and a generated
Registry:

```elixir
{:ok, stored_map, temporary_registry} = Jido.Flow.Codec.encode(flow)
```

Keep that Registry for decoding. Generated identifiers are not stable across
Flow, module, or schema changes. Do not use them for durable storage.

Use `Jido.Flow.Codec.diagnose/2` when an editor needs all independent document
and graph errors in one result.

## Update Error Handling

The concrete `Jido.Action.Error` exception names remain available. Existing
matches on `InvalidInputError`, `ExecutionFailureError`, `TimeoutError`,
`ConfigurationError`, and `InternalError` can often stay.

Version 3 makes the boundary stricter:

- errors are non-retryable unless a concrete execution or timeout error has
  `details.retry: true`;
- an unknown value becomes a conservative Action execution error;
- `Jido.Exec` does not retry a retryable error; and
- Flow definition and execution errors use `Jido.Flow.Error`.

Use `Jido.Action.Error.to_map/1` or `Jido.Flow.Error.to_map/1` when an HTTP,
JSON, or UI boundary needs stable data.

## Update Supervisor Names

The default v2 Task Supervisor is `Jido.Action.TaskSupervisor`. The default v3
Task Supervisor is `Jido.Exec.TaskSupervisor`. The package application starts
it.

Update code that refers to the old global supervisor by name.

Instance routing keeps the same convention. `jido: MyApp.Jido` selects
`MyApp.Jido.TaskSupervisor`. The instance must start that supervisor. Version
3 returns a structured error when it is not running and does not fall back to
the global supervisor. Higher-level runtimes can use
`Jido.Exec.task_supervisor_name/1` when they build the instance supervision
tree.

## Verify The Upgrade

Use this check for each application:

1. Remove unsupported Action options and callbacks.
2. Convert each NimbleOptions Action schema to a static Zoi object schema.
3. Replace Instruction `action`, `id`, and `opts` fields.
4. Remove v2 instruction shorthand normalization.
5. Move timeout defaults, retry, compensation, and cancellation to the caller.
6. Replace Plans and reusable Chains with explicit Flows where this is useful.
7. Replace tool, catalog, and bundled-tool integrations outside this package.
8. Update global supervisor names.
9. Compile with warnings as errors.
10. Test Action input, output, error, timeout, and process-exit boundaries.
11. Test each Flow through both complete and step-wise execution when you use
    both APIs.
12. Round-trip stored Flows through real JSON bytes and the trusted Registry.

See [Actions](actions.md), [Instructions](instructions.md),
[Direct Construction And Builder](flow-builder.md),
[Execution Contract](execution.md), and [Store Flows As JSON](flow-storage.md)
for the v3 contracts.
