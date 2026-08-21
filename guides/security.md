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
registry entry before you store or execute it.

Do not create atoms from untrusted input. Keep user-provided identifiers as
strings. A stored Flow map or stored Flow source can use only atoms that
already exist in the VM. Accepted and rejected artifacts do not create atoms.

The atom map key `:__struct__` is reserved in a stored Flow map. The reader and
writer reject it before they construct an Elixir map. The string map key
`"__struct__"` is valid. The atom `:__struct__` is also valid as a typed
reference path segment because a path does not construct a map.

## Limit Stored Flow Input

The library applies these fixed limits to each stored Flow map:

- Maximum container depth: 64.
- Maximum visited term count: 100,000.
- Maximum total binary payload: 1,048,576 bytes.
- Maximum width of one map, list, or tuple: 10,000 items.

The binary limit is the total for the complete artifact. `Flow.from_map/2`
receives a decoded map. It does not limit raw HTTP bytes or JSON decoder work.
The caller must limit transport bytes and JSON decoding before it calls
`Flow.from_map/2`.

For stored source, the library applies a 1,048,576-byte source limit before
`Code.string_to_quoted/2`. It then applies the same depth, term-count, binary,
and collection-width limits to the quoted AST before DSL traversal.

Stored source is restricted developer syntax. It is not a hostile-input
sandbox. Use the stored map format, with caller-owned transport limits, for
untrusted ingress.

## Control Contract Bundles In The Host

A stored version 1 map contains stable contract and Action identifiers. The
host supplies an allow-list of `%Jido.Flow.ContractBundle{}` values through the
`contract_bundles:` option. The allow-list key must equal the selected bundle
ID. Zoi schemas, Action module atoms, and bundle contents stay in host code.

Bundle selection and resolution are inert. They can normalize trusted maps and
do pure lookup. They do not load a module, call an Action callback, validate
data through a Zoi schema, call `Flow.check/1`, emit telemetry, compile, or
execute the Flow.

Stored decode, inspection, identity, and compile also do not check target
contracts. `Flow.check/1` and `Jido.Exec` own those checks. Retry, timeout,
persistence, and durability policy stay outside the Flow artifact.

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
