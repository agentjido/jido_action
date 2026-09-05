defmodule Jido.Flow.Error do
  @moduledoc """
  Defines and normalizes errors owned by Jido Flows.

  Flow errors cover authoring data, compilation, native Runic coordination,
  and Flow execution state. An Action failure inside a Flow keeps its original
  `Jido.Action.Error` type. This module can merge those Action errors when one
  Flow operation has more than one failure.
  """

  use Splode,
    error_classes: [
      invalid: __MODULE__.Invalid,
      execution: __MODULE__.Execution,
      internal: __MODULE__.Internal
    ],
    unknown_error: __MODULE__.Internal.UnknownError,
    merge_with: [Jido.Action.Error]

  alias Jido.Action.Error, as: ActionError
  alias Jido.Action.Error.ExternalData

  @type details_input :: map() | keyword()
  @type runnable_failure :: %{
          node: term(),
          runnable_id: Runic.Identity.t() | integer(),
          error: Exception.t()
        }
  @type error_map :: ActionError.error_map()

  defmodule Invalid do
    @moduledoc "An ordered group of invalid Flow definition errors."
    use Splode.ErrorClass, class: :invalid

    @type t :: %__MODULE__{errors: [Exception.t()]}
  end

  defmodule Execution do
    @moduledoc false
    use Splode.ErrorClass, class: :execution
  end

  defmodule Internal do
    @moduledoc false
    use Splode.ErrorClass, class: :internal

    defmodule UnknownError do
      @moduledoc false
      use Splode.Error,
        class: :internal,
        fields: [message: "Unknown Flow error", error: nil, details: %{}]

      @type t :: %__MODULE__{
              message: String.t(),
              error: any() | nil,
              details: map()
            }

      @spec message(t()) :: String.t()
      def message(%{error: error}) when not is_nil(error), do: normalize_message(error)
      def message(%{message: message}), do: message

      defp normalize_message(message) when is_binary(message), do: message
      defp normalize_message(message) when is_atom(message), do: Atom.to_string(message)
      defp normalize_message(message), do: inspect(message)
    end
  end

  defmodule InvalidDefinitionError do
    @moduledoc "Error for invalid canonical Flow data or authoring input."
    use Splode.Error,
      class: :invalid,
      fields: [message: "Invalid Flow definition", details: %{}]

    @type t :: %__MODULE__{message: String.t(), details: map()}
  end

  defmodule InvalidExecutionError do
    @moduledoc "Error for invalid Flow execution input or state."
    use Splode.Error,
      class: :invalid,
      fields: [message: "Invalid Flow execution", details: %{}]

    @type t :: %__MODULE__{message: String.t(), details: map()}
  end

  defmodule ExecutionFailureError do
    @moduledoc "Error for native Flow execution failures."
    use Splode.Error,
      class: :execution,
      fields: [message: "Flow execution failed", flow: nil, failures: [], details: %{}]

    @type t :: %__MODULE__{
            message: String.t(),
            flow: String.t() | nil,
            failures: [Jido.Flow.Error.runnable_failure()],
            details: map()
          }
  end

  defmodule TimeoutError do
    @moduledoc "Error for a Flow execution timeout."
    use Splode.Error,
      class: :execution,
      fields: [message: "Flow execution timed out", flow: nil, timeout: nil, details: %{}]

    @type t :: %__MODULE__{
            message: String.t(),
            flow: String.t() | module() | nil,
            timeout: non_neg_integer() | nil,
            details: map()
          }
  end

  defmodule InternalError do
    @moduledoc "Error for an unexpected internal Flow failure."
    use Splode.Error,
      class: :internal,
      fields: [message: "Internal Flow error", details: %{}]

    @type t :: %__MODULE__{message: String.t(), details: map()}
  end

  @doc "Creates an invalid Flow definition error."
  @spec validation_error(String.t(), details_input()) :: InvalidDefinitionError.t()
  def validation_error(message, details \\ %{}) do
    InvalidDefinitionError.exception(message: message, details: normalize_input(details))
  end

  @doc "Creates an invalid Flow execution input or state error."
  @spec invalid_execution_error(String.t(), details_input()) :: InvalidExecutionError.t()
  def invalid_execution_error(message, details \\ %{}) do
    InvalidExecutionError.exception(message: message, details: normalize_input(details))
  end

  @doc "Creates a Flow execution failure."
  @spec execution_error(String.t(), details_input()) :: ExecutionFailureError.t()
  def execution_error(message, details \\ %{}) do
    ExecutionFailureError.exception(message: message, details: normalize_input(details))
  end

  @doc "Creates a Flow timeout error."
  @spec timeout_error(String.t(), details_input()) :: TimeoutError.t()
  def timeout_error(message, details \\ %{}) do
    details = normalize_input(details)

    TimeoutError.exception(
      message: message,
      flow: Map.get(details, :flow),
      timeout: Map.get(details, :timeout),
      details: details
    )
  end

  @doc "Creates one failure for a Flow operation with failed Runic runnables."
  @spec flow_failure(String.t(), [runnable_failure()]) :: ExecutionFailureError.t()
  def flow_failure(flow, failures) when is_binary(flow) and is_list(failures) do
    ExecutionFailureError.exception(
      message: "Flow #{inspect(flow)} failed in #{length(failures)} runnables",
      flow: flow,
      failures: failures
    )
  end

  @doc "Creates an internal Flow error."
  @spec internal_error(String.t(), details_input()) :: InternalError.t()
  def internal_error(message, details \\ %{}) do
    InternalError.exception(message: message, details: normalize_input(details))
  end

  @doc """
  Converts a Flow or Action error into its stable public map.

  Uses the bounded conversion rules in `Jido.Action.Error.to_map/1`.
  The original error retains its complete details and stacktrace in memory.
  """
  @spec to_map(term()) :: error_map()
  def to_map(error), do: error |> external_data() |> ExternalData.to_map()

  @doc false
  @spec external_data(term()) :: map()
  def external_data({:error, reason, _effects}), do: external_data(reason)
  def external_data({:error, reason}), do: external_data(reason)

  def external_data(%InvalidDefinitionError{} = error) do
    ExternalData.error_data(:flow_definition_error, error.message, error.details, false)
  end

  def external_data(%InvalidExecutionError{} = error) do
    ExternalData.error_data(:flow_invalid_execution, error.message, error.details, false)
  end

  def external_data(%ExecutionFailureError{} = error) do
    fields =
      %{}
      |> maybe_put(:flow, error.flow)
      |> maybe_put_failures(error.failures)

    ExternalData.error_data(
      :flow_execution_error,
      error.message,
      error.details,
      retryable?(error),
      Map.to_list(fields)
    )
  end

  def external_data(%TimeoutError{} = error) do
    ExternalData.error_data(:flow_timeout, error.message, error.details, retryable?(error),
      flow: error.flow,
      timeout: error.timeout
    )
  end

  def external_data(%InternalError{} = error) do
    ExternalData.error_data(:flow_internal_error, error.message, error.details, false)
  end

  def external_data(%Internal.UnknownError{} = error) do
    message = if is_nil(error.error), do: error.message, else: error.error
    ExternalData.error_data(:flow_internal_error, message, error.details, false)
  end

  def external_data(%Invalid{errors: errors}) do
    ExternalData.error_data(
      :flow_definition_error,
      "Invalid Flow",
      error_list_details(errors),
      false
    )
  end

  def external_data(%Execution{errors: errors}) do
    ExternalData.error_data(
      :flow_execution_error,
      "Flow execution failed",
      error_list_details(errors),
      false
    )
  end

  def external_data(%Internal{errors: errors}) do
    ExternalData.error_data(
      :flow_internal_error,
      "Internal Flow error",
      error_list_details(errors),
      false
    )
  end

  def external_data(error), do: ActionError.external_data(error)

  @doc "Returns whether a Flow or Action error is retryable."
  @spec retryable?(term()) :: boolean()
  def retryable?({:error, reason, _effects}), do: retryable?(reason)
  def retryable?({:error, reason}), do: retryable?(reason)

  def retryable?(%ExecutionFailureError{details: %{retry: retry}})
      when is_boolean(retry),
      do: retry

  def retryable?(%ExecutionFailureError{}), do: false
  def retryable?(%TimeoutError{details: %{retry: retry}}) when is_boolean(retry), do: retry
  def retryable?(%TimeoutError{}), do: false
  def retryable?(%InvalidDefinitionError{}), do: false
  def retryable?(%InvalidExecutionError{}), do: false
  def retryable?(%InternalError{}), do: false
  def retryable?(%Internal.UnknownError{}), do: false
  def retryable?(%Invalid{}), do: false
  def retryable?(%Execution{}), do: false
  def retryable?(%Internal{}), do: false
  def retryable?(error), do: ActionError.retryable?(error)

  @doc false
  @spec owned?(term()) :: boolean()
  def owned?(%InvalidDefinitionError{}), do: true
  def owned?(%InvalidExecutionError{}), do: true
  def owned?(%ExecutionFailureError{}), do: true
  def owned?(%TimeoutError{}), do: true
  def owned?(%InternalError{}), do: true
  def owned?(%Internal.UnknownError{}), do: true
  def owned?(%Invalid{}), do: true
  def owned?(%Execution{}), do: true
  def owned?(%Internal{}), do: true
  def owned?(_error), do: false

  defp error_list_details(errors),
    do: %{errors: ExternalData.map_items(errors, &nested_error/1)}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_failures(details, []), do: details

  defp maybe_put_failures(details, failures) do
    Map.put(details, :failures, ExternalData.map_items(failures, &failure_to_map/1))
  end

  defp failure_to_map(%{node: node, runnable_id: runnable_id, error: error}) do
    %{node: node, runnable_id: runnable_id, error: nested_error(error)}
  end

  defp failure_to_map(value), do: value

  defp nested_error(error), do: %ExternalData.NestedError{error: error}

  defp normalize_input(details) when is_map(details) and not is_struct(details), do: details

  defp normalize_input(details) when is_list(details),
    do: if(Keyword.keyword?(details), do: Map.new(details), else: %{})

  defp normalize_input(_details), do: %{}
end

defimpl JSON.Encoder,
  for: [
    Jido.Flow.Error.InvalidDefinitionError,
    Jido.Flow.Error.InvalidExecutionError,
    Jido.Flow.Error.ExecutionFailureError,
    Jido.Flow.Error.TimeoutError,
    Jido.Flow.Error.InternalError,
    Jido.Flow.Error.Internal.UnknownError,
    Jido.Flow.Error.Invalid,
    Jido.Flow.Error.Execution,
    Jido.Flow.Error.Internal
  ] do
  def encode(error, opts) do
    error
    |> Jido.Flow.Error.to_map()
    |> JSON.Encoder.encode(opts)
  end
end
