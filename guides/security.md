# Security

Jido Action provides data contracts and execution boundaries. Your application
must still control authorization, effects, secrets, and runtime limits.

## Validate Action Inputs

Use an Action schema to reject malformed data before `run/2` executes. Validate
authorization and ownership again when they depend on external state.

```elixir
defmodule MyApp.Actions.ReadFile do
  use Jido.Action,
    name: "read_file",
    schema: Zoi.object(%{path: Zoi.string() |> Zoi.min(1)}),
    output_schema: Zoi.object(%{contents: Zoi.string()})

  @impl true
  def run(%{path: path}, %{allowed_root: root}) do
    allowed_root = Path.expand(root)
    expanded = Path.expand(path, allowed_root)
    relative = Path.relative_to(expanded, allowed_root)

    if relative == ".." or String.starts_with?(relative, "../") do
      {:error, Jido.Action.Error.validation_error("path outside allowed root")}
    else
      {:ok, %{contents: File.read!(expanded)}}
    end
  end
end
```

Schemas are not authorization. Keep tenant checks, capability checks, and
resource ownership checks inside the application boundary.

## Keep Effects Explicit

Actions can perform file, network, database, and process effects. Make these
effects visible in the Action name, input schema, context contract, and tests.
Pass only the capabilities that the Action needs.

Context can contain request metadata, credentials, tenant identifiers, and
tracing state. Treat it as sensitive input. Do not copy secrets into Flow
results, error details, or logs.

## Treat Flow Script As Code Data

Flow Script authoring has two security profiles:

- **Trusted profile:** use only for source-controlled definitions. Source can
  refer directly to Action modules.
- **Stored profile:** use for persisted or user supplied definitions. Use an
  explicit allow-list registry and the parser safety limits. Do not resolve
  arbitrary modules from input text.

Keep Flow Script text and registries separate from untrusted request data.
Accept only a successful parser result. Inspect the result and authorize every
registry entry before you store or execute it. Do not turn input strings into
atoms. Keep user identifiers as strings, or use
`String.to_existing_atom/1` with a bounded set of preloaded atoms.

## Bound Runtime Policy

The current Flow execution API supports only `async` and
`max_concurrency`. It does not provide retries, retry backoff, per-node
timeouts, deadlines, cancellation, rewind, or persistent checkpoints.

Set caller-owned supervision, process limits, request deadlines, and external
retry policy around `Jido.Exec`. Limit `max_concurrency` to a value that the
application can support. Do not assume asynchronous execution provides a
timeout; the current scheduler uses an internal task timeout of `:infinity`.

## Design For Repeat Risk

Every step returns a new immutable execution value. Reusing a stale value can
run an Action again. A process restart can also cause a caller to repeat work.
Jido does not provide exactly-once guarantees for external effects.

Use idempotency keys, conditional writes, deduplication, or transactional
boundaries for effects that must not run twice. Include the Flow execution or
request identity in those keys when the domain supports it.

## Protect Errors And Telemetry

Error structs and telemetry can include Action names, Flow names, node names,
and error details. Do not include raw credentials, tokens, personal data, or
full context maps in error messages or telemetry metadata.

Redact before logging or exporting errors outside the execution boundary.
Treat telemetry handlers as a data access boundary and restrict who can read
their output.
