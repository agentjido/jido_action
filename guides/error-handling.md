# Error Handling

`jido_action` normalizes action failures into structured exceptions under `Jido.Action.Error`.

## Common Errors

- `Jido.Action.Error.InvalidInputError` - parameter or output validation failed.
- `Jido.Action.Error.ConfigurationError` - action configuration is invalid.
- `Jido.Action.Error.ExecutionFailureError` - action returned an invalid shape or failed during execution.
- `Jido.Action.Error.TimeoutError` - action exceeded its runtime budget.
- `Jido.Action.Error.InternalError` - unexpected internal failure.

Serialized errors use a small canonical `:type` set:

- `:validation_error`
- `:configuration_error`
- `:execution_error`
- `:timeout`
- `:internal_error`

Specific runtime or adapter reasons belong in `details.kind` or
`details.reason`, not in the top-level `type`.

## Returning Errors

Actions can return any reason:

```elixir
def run(%{path: path}, _context) do
  if File.exists?(path) do
    {:ok, %{path: path}}
  else
    {:error, Jido.Action.Error.execution_error("file not found", path: path)}
  end
end
```

Three-tuple errors preserve the third value:

```elixir
{:error, reason, extra}
```

## Exceptions And Exits

`Jido.Exec` catches exceptions, throws, and abnormal exits from supervised execution and returns structured error tuples. Direct `run/2` calls do not add that protection.

## Retryability

Use `Jido.Action.Error.retryable?/1` to apply the same retry decision logic as `Jido.Exec`.

```elixir
if Jido.Action.Error.retryable?(reason) do
  :retry
else
  :stop
end
```

Validation and configuration errors are not retryable. Timeout and structured
execution failures usually are retryable. Raw atom reasons such as
`:econnreset` or `:transient_error` are normalized as opaque execution reasons
and are not retryable unless the action returns an explicit retry hint, for
example `Jido.Action.Error.execution_error("temporary", retry: true)`.

## Serialization

Use `Jido.Action.Error.to_map/1` when errors need to cross process, logging, or API boundaries.

```elixir
error
|> Jido.Action.Error.to_map()
|> Jason.encode!()
```

Noncanonical map or atom reasons are folded into the stable shape:

```elixir
Jido.Action.Error.to_map(:econnreset)
# %{
#   type: :execution_error,
#   message: "econnreset",
#   details: %{reason: :econnreset},
#   retryable?: false
# }
```
