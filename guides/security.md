# Security

Actions are ordinary Elixir modules. Security comes from precise validation, explicit effects, bounded execution, and careful context handling.

## Validate Inputs

Use Zoi schemas to reject malformed data before `run/2` executes.

```elixir
schema:
  Zoi.object(%{
    user_id: Zoi.string() |> Zoi.min(1),
    limit: Zoi.integer() |> Zoi.min(1) |> Zoi.max(100) |> Zoi.default(25)
  })
```

Validate boundary data again inside `run/2` when it depends on external state, authorization, or resource ownership.

## Keep Effects Explicit

Make file, network, database, and process effects visible in the action name, schema, and tests.

```elixir
def run(%{path: path}, %{allowed_root: root}) do
  expanded = Path.expand(path, root)

  if String.starts_with?(expanded, Path.expand(root)) do
    {:ok, %{contents: File.read!(expanded)}}
  else
    {:error, Jido.Action.Error.validation_error("path outside allowed root")}
  end
end
```

## Bound Runtime

Use caller-owned supervision, timeouts, or retry boundaries when production
actions need runtime limits.

Do not retry a non-idempotent effect unless the action is explicitly safe to
repeat. `Jido.Exec` does not currently provide a Flow retry option.

## Treat Context As Sensitive

Context often carries request metadata, credentials, tenant identifiers, or tracing state. Pass only what the action needs, and do not include secrets in error details.

Apply domain-specific redaction before logging arbitrary params, context, or errors outside the execution boundary.

## Prefer Existing Atoms

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

Actions that spawn their own processes remain responsible for cleaning them up.
