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

Direct `run/2` calls do not add supervision or crash isolation. Callers that
need crash normalization, retries, or timeouts should own that runtime boundary.

## Retryability

Use `Jido.Action.Error.retryable?/1` when adapter code needs a conservative
classification for an action-layer error.

```elixir
if Jido.Action.Error.retryable?(reason) do
  :retry
else
  :stop
end
```

Validation and configuration errors are not retryable. Timeout and structured
execution failures are retryable by default. An execution error can disable a
retry with a direct hint:

```elixir
Jido.Action.Error.execution_error("do not retry", retry: false)
```

Raw values, foreign maps, and nested retry hints are not retryable. Only a
concrete Jido Action error can define retry policy.

## Serialization

Use `Jido.Action.Error.to_map/1` when errors need to cross process, logging, or API boundaries.

```elixir
error
|> Jido.Action.Error.to_map()
|> JSON.encode!()
```

Unsupported reasons use one conservative fallback:

```elixir
Jido.Action.Error.to_map(:econnreset)
# %{
#   type: :execution_error,
#   message: "econnreset",
#   details: %{reason: :econnreset},
#   retryable?: false
# }
```

Only concrete Jido Action errors keep structured details. Foreign maps cannot
select a canonical error type. Constructors accept plain maps or keyword lists
for details. JSON conversion can replace unsupported values with strings and
can discard colliding keys after normalization.
