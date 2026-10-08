# Errors

Every failure from `Jido.Exec`, `Jido.Flow`, `Jido.Instruction`, and
`Jido.Flow.Codec` is an exception struct in a `{:error, exception}` tuple.
This guide lists the structs, shows which phase produces each one, and
explains how to handle them.

## Two Error Families

| Family | Covers | Structs |
| --- | --- | --- |
| `Jido.Action.Error` | Action input and output validation, Action failures, timeouts, options, and target resolution. | `InvalidInputError`, `ExecutionFailureError`, `TimeoutError`, `ConfigurationError`, `InternalError` |
| `Jido.Flow.Error` | Flow definitions, stored documents, and Flow coordination at runtime. | `InvalidDefinitionError`, `InvalidExecutionError`, `ExecutionFailureError`, `TimeoutError`, `InternalError`, and the `Invalid` group |

An Action that fails inside a Flow keeps its `Jido.Action.Error` type. The
Flow adds location details such as `node` and `node_path`.

Every struct has a `message` and a `details` map. Match on the struct module
and on `details` keys. Do not match on message text.

## Handle An Error

```elixir
case Jido.Exec.run(MyApp.Actions.ChargeCard, params, context) do
  {:ok, result} ->
    {:ok, result}

  {:ok, result, effects} ->
    {:ok, result, effects}

  {:error, %Jido.Action.Error.InvalidInputError{} = error} ->
    {:error, {:invalid, Exception.message(error)}}

  {:error, %Jido.Action.Error.TimeoutError{}} ->
    {:error, :timeout}

  {:error, error} ->
    Logger.error("charge failed", error: Jido.Flow.Error.to_map(error))
    {:error, :failed}
end
```

## Convert An Error To A Map

Use `Jido.Flow.Error.to_map/1` for any error from this package. It handles
both families. `Jido.Action.Error.to_map/1` handles only Action errors.

```elixir
Jido.Flow.Error.to_map(error)
#=> %{
#=>   type: :execution_error,
#=>   message: "not_available",
#=>   details: %{action: MyApp.Actions.ChargeCard, reason: :not_available, phase: :run},
#=>   retryable?: false
#=> }
```

| Struct | `type` |
| --- | --- |
| `Jido.Action.Error.InvalidInputError` | `:validation_error` |
| `Jido.Action.Error.ExecutionFailureError` | `:execution_error` |
| `Jido.Action.Error.TimeoutError` | `:timeout` |
| `Jido.Action.Error.ConfigurationError` | `:configuration_error` |
| `Jido.Action.Error.InternalError` | `:internal_error` |
| `Jido.Flow.Error.InvalidDefinitionError` and `Invalid` | `:flow_definition_error` |
| `Jido.Flow.Error.InvalidExecutionError` | `:flow_invalid_execution` |
| `Jido.Flow.Error.ExecutionFailureError` | `:flow_execution_error` |
| `Jido.Flow.Error.TimeoutError` | `:flow_timeout` |
| `Jido.Flow.Error.InternalError` | `:flow_internal_error` |

The map keeps detail values unchanged. Details can contain modules,
stacktraces, and other Elixir terms. Convert or redact them before you send
the map through JSON or to an external log. See [Security](security.md).

## Errors By Phase

### Before Work Starts

| Cause | Error | Useful details |
| --- | --- | --- |
| Unknown or invalid `run/4` option | `Jido.Action.Error.ConfigurationError` | `options` |
| Unknown target module | `Jido.Action.Error.ConfigurationError` | `target`, `reason` |
| Invalid Instruction fields | `Jido.Action.Error.InvalidInputError` | `reason`, `fields` |
| Invalid Flow definition, from `Jido.Flow.new/1`, `validate/1`, or compilation | `Jido.Flow.Error.InvalidDefinitionError` | `component`, `field`, `owner` |
| Invalid stored document, from `Jido.Flow.Codec.diagnose/2` | `Jido.Flow.Error.Invalid` | `errors`, each with its document path |
| Invalid Flow input | `Jido.Action.Error.InvalidInputError` | `phase: :flow_input`, `errors` |

### While An Action Runs

| Cause | Error | Useful details |
| --- | --- | --- |
| Input fails the Action schema | `Jido.Action.Error.InvalidInputError` | `context: "Action"`, `errors` |
| `run/2` returns `{:error, exception}` | That exception, unchanged | Your details |
| `run/2` returns `{:error, term}` | `Jido.Action.Error.ExecutionFailureError` | `reason`, `phase: :run` |
| `run/2` raises | `Jido.Action.Error.ExecutionFailureError` with the exception message | `exception`, `stacktrace` |
| `run/2` throws or exits | `Jido.Action.Error.ExecutionFailureError` | `kind`, `reason`, `stacktrace` |
| `run/2` returns another shape | `Jido.Action.Error.ExecutionFailureError` | `reason: :invalid_return`, `return` |
| Effects are not a proper list | `Jido.Action.Error.ExecutionFailureError` | `reason: :invalid_effects` |
| `{:continue, ...}` outside a Dispatch expander | `Jido.Action.Error.ExecutionFailureError` | `reason: :unsupported_continuation` |
| Output fails the output schema | `Jido.Action.Error.InvalidInputError` | `context: "Action output"`, `errors` |
| An attempt exceeds `timeout` | `Jido.Action.Error.TimeoutError` | `timeout` |

Each `errors` entry from schema validation has a `code`, a `message`, and a
`path` into the data.

### While A Flow Coordinates Work

An Action failure inside a Flow adds `node`, `node_path`, and, for module
Flows, `source` (file and line). Collection and loop failures add
`item_index` and `item_id`, or `iteration_index`.

Flow coordination failures use `Jido.Flow.Error.ExecutionFailureError`. Its
`details.reason` identifies the cause:

| `reason` or `phase` | Cause |
| --- | --- |
| `:missing_key`, `:missing_index`, `:not_traversable` | A reference path does not exist in the data. |
| `phase: :choice_condition` | A Choice condition did not return a Boolean. |
| `phase: :reduce_collection`, `:reduce_initial` | A Reduce collection or initial value is invalid. |
| `phase: :iterate_state_initial`, `:iterate_state_update` | Iterate state failed its schema. |
| `phase: :iterate_completion` | An Iterate completion condition did not return a Boolean. |
| `phase: :iterate_exhaustion` | An Iterate reached `max_iterations` before it completed. |

Flow input and output schemas use the same validator as Actions. A Flow
output that fails its `output_schema`, or a nested Flow input that fails its
`schema`, returns `Jido.Action.Error.InvalidInputError` with
`details.phase` set to `:flow_output`, `:subflow_output`, or
`:subflow_input`.

### Execution Process Failures

| Cause | Error | Useful details |
| --- | --- | --- |
| The execution task was killed | `Jido.Action.Error.ExecutionFailureError` | `phase: :execution_task`, `reason` |
| Managed params, context, output, or effects contain a PID, port, reference, or function | `Jido.Action.Error.ExecutionFailureError` | `phase: :durability`, `reason: :non_portable_durable_value`, `path`, `type` |
| Another Runic failure | `Jido.Action.Error.ExecutionFailureError` | `reason` |

## Return Your Own Errors

Return a `Jido.Action.Error` struct from `run/2` when callers need structured
details. Exec returns it unchanged:

```elixir
def run(%{symbol: symbol}, _context) do
  case MyApp.Quotes.fetch(symbol) do
    {:ok, quote} ->
      {:ok, %{price: quote.price}}

    {:error, :unavailable} ->
      {:error,
       Jido.Action.Error.execution_error("Quote service is unavailable", %{
         service: :quotes,
         retry: true
       })}
  end
end
```

The constructors are `validation_error/2`, `execution_error/2`,
`config_error/2`, `timeout_error/2`, and `internal_error/2`. Each takes a
message and a details map or keyword list.

## Retry Classification

`Jido.Action.Error.retryable?/1` and `Jido.Flow.Error.retryable?/1` return
`true` only for an `ExecutionFailureError` or `TimeoutError` whose details
contain `retry: true`. Every other error is not retryable.

Exec uses this classification when `max_attempts` allows another attempt. Set
`details.retry: true` only when repeated work is safe. See
[Execution](execution.md#retries).

## Failures In Logs

Runic logs a warning for each failed runnable. In tests, wrap expected
failures with `ExUnit.CaptureLog.capture_log/1` or set
`@moduletag capture_log: true`.
