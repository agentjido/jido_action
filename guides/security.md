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

## Keep DSL Source At Compile Time

The Flow module DSL is compile-time Elixir source. Keep it in trusted
application code. Do not evaluate generated or user-supplied Elixir source to
create a Flow. Use `Jido.Flow.Codec` and JSON for database data, API input, and
AI-generated Flows.

Do not create atoms from untrusted input. Keep user-provided identifiers as
strings. A stored Flow map can select data atoms only through trusted
`{:atom, atom}` Registry entries. Accepted and rejected artifacts do not create
atoms and do not use the VM atom table as an implicit Registry.

## Limit Stored Flow Input

The Codec applies these limits while it encodes and decodes:

- Maximum container depth: 100.
- Maximum width of one map or list: 10,000 items.

`Jido.Flow.Codec.decode/2` receives a decoded map. It does not limit raw HTTP
bytes or JSON decoder work. The caller must set transport-byte, JSON-parser,
and complete-document limits before it calls the Codec.

## Control The Registry In The Host

A stored Flow map contains stable schema, Action, Flow, and data atom
identifiers. The host supplies one flat `Jido.Flow.Registry`. Zoi schemas,
module atoms, and data atoms stay in host code. Stored data can select only
identifiers that the Registry owns.

Registry resolution is inert. It validates trusted entries and does direct
lookup. It does not derive module names, create atoms, load a module, call an
Action callback, validate data through a schema, emit telemetry, or execute the
Flow.

Stored decode, inspection, and identity do not check target contracts.
`Jido.Flow.validate_executable/1` checks them without execution, and `Jido.Exec`
repeats the check at the execution boundary. Retry, timeout, persistence, and
durability policy stay outside the Flow artifact.

## Bound Runtime Policy

The current Flow execution API supports only `async` and `max_concurrency` as
policy options. The common `jido:` option selects OTP instance routing. It does
not add a runtime policy. The API does not provide retries, retry backoff,
per-node timeouts, deadlines, cancellation, rewind, or persistent checkpoints.

Set caller-owned supervision, process limits, request deadlines, and external
retry policy around `Jido.Exec`. Limit `max_concurrency` to a value that the
application can support. Do not assume asynchronous execution provides a
timeout; the current scheduler uses an internal task timeout of `:infinity`.

## Bound Collections And Iterate Nodes

`max_concurrency` limits active Action calls and asynchronous helper workers
across concurrent nodes, Map items, and nested Flow targets in one execution.
Nested work runs inline when all helper-worker slots are in use. This avoids a
queue of waiting task processes. The option does not limit the number of items
in the input list. Validate collection size at the application boundary.
Remember that `:collect_errors` can retain one record for each failed item.

Every Iterate node has an iteration bound. Keep `repeat` and `max_iterations`
small enough for the target cost. Iterate State is in-memory data. Do not put
secrets in State or body output when errors, inspection, or telemetry can
expose their shape.

## Design For Repeat Risk

Every step returns a new immutable execution value. Reusing a stale value can
run an Action again. A process restart can also cause a caller to repeat work.
Jido does not provide exactly-once guarantees for external effects.

Use idempotency keys, conditional writes, deduplication, or transactional
boundaries for effects that must not run twice. Include the Flow execution or
request identity in those keys when the domain supports it.

## Protect Errors And Telemetry

Error structs and telemetry can include Action names, Flow names, node names,
error details, and runtime stacktraces. Stacktraces can include source paths,
line numbers, and retained argument terms. Do not include raw credentials,
tokens, personal data, or full context maps in error messages or telemetry
metadata.

Redact before logging or exporting errors outside the execution boundary.
Treat telemetry handlers as a data access boundary and restrict who can read
their output.
