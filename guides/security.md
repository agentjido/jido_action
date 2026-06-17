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

Run production actions through `Jido.Exec` with timeouts and retry limits.

```elixir
Jido.Exec.run(MyAction, params, context, timeout: 2_000, max_retries: 1)
```

Use `max_retries: 0` for non-idempotent effects unless the action is explicitly safe to retry.

## Treat Context As Sensitive

Context often carries request metadata, credentials, tenant identifiers, or tracing state. Pass only what the action needs, and do not include secrets in error details.

Use `Jido.Action.Sanitizer` or your own redaction before logging arbitrary params, context, or errors.

## Prefer Existing Atoms

Do not create atoms from untrusted input. Keep user-provided identifiers as strings or use `String.to_existing_atom/1` only for a bounded, preloaded set.

## Async Cleanup

For long-running or async work, test timeout and cancellation cleanup. `Jido.Exec` supervises action execution, but actions that spawn their own processes remain responsible for cleaning them up.

