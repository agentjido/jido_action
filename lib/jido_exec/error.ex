defmodule Jido.Exec.Error do
  @moduledoc """
  Defines errors for the target-neutral asynchronous execution lifecycle.

  Action and Flow failures keep their original error types. These errors cover
  only handle validation, message handling, waiting, cancellation, and
  failures of the managed asynchronous execution process.
  """

  alias Jido.Action.Error.ExternalData

  @type details_input :: map() | keyword()
  @type error_map :: %{
          type: atom(),
          message: String.t(),
          details: map(),
          retryable?: false
        }

  defmodule InvalidHandleError do
    @moduledoc "Error for an invalid asynchronous execution handle or operation."
    defexception message: "Invalid asynchronous execution handle", details: %{}

    @type t :: %__MODULE__{message: String.t(), details: map()}
  end

  defmodule AsyncTimeoutError do
    @moduledoc "Error for an asynchronous wait timeout."
    defexception message: "Asynchronous execution timed out", timeout: nil, details: %{}

    @type t :: %__MODULE__{
            message: String.t(),
            timeout: non_neg_integer() | nil,
            details: map()
          }
  end

  defmodule AsyncExecutionError do
    @moduledoc "Error for a failure of the managed asynchronous execution process."
    defexception message: "Asynchronous execution failed", details: %{}

    @type t :: %__MODULE__{message: String.t(), details: map()}
  end

  defmodule CancelledError do
    @moduledoc "Error used to terminate a cancelled asynchronous execution."
    defexception message: "Asynchronous execution was cancelled", details: %{}

    @type t :: %__MODULE__{message: String.t(), details: map()}
  end

  @doc "Creates an invalid-handle error."
  @spec invalid_handle_error(String.t(), details_input()) :: InvalidHandleError.t()
  def invalid_handle_error(message, details \\ %{}) do
    InvalidHandleError.exception(message: message, details: normalize_details(details))
  end

  @doc "Creates an asynchronous wait timeout error."
  @spec timeout_error(String.t(), details_input()) :: AsyncTimeoutError.t()
  def timeout_error(message, details \\ %{}) do
    details = normalize_details(details)

    AsyncTimeoutError.exception(
      message: message,
      timeout: Map.get(details, :timeout),
      details: details
    )
  end

  @doc "Creates an asynchronous execution-process error."
  @spec execution_error(String.t(), details_input()) :: AsyncExecutionError.t()
  def execution_error(message, details \\ %{}) do
    AsyncExecutionError.exception(message: message, details: normalize_details(details))
  end

  @doc "Creates an asynchronous cancellation error."
  @spec cancelled_error(String.t(), details_input()) :: CancelledError.t()
  def cancelled_error(message \\ "Asynchronous execution was cancelled", details \\ %{}) do
    CancelledError.exception(message: message, details: normalize_details(details))
  end

  @doc "Returns whether a value is an error owned by the async execution boundary."
  @spec owned?(term()) :: boolean()
  def owned?(%InvalidHandleError{}), do: true
  def owned?(%AsyncTimeoutError{}), do: true
  def owned?(%AsyncExecutionError{}), do: true
  def owned?(%CancelledError{}), do: true
  def owned?(_error), do: false

  @doc """
  Converts an async execution error into stable external data.

  Uses the bounded conversion rules in `Jido.Action.Error.to_map/1`.
  The original error retains its complete details in memory.
  """
  @spec to_map(Exception.t()) :: error_map()
  def to_map(%InvalidHandleError{} = error),
    do: error_map(:async_invalid_handle, error.message, error.details)

  def to_map(%AsyncTimeoutError{} = error) do
    error_map(:async_timeout, error.message, error.details, timeout: error.timeout)
  end

  def to_map(%AsyncExecutionError{} = error),
    do: error_map(:async_execution_error, error.message, error.details)

  def to_map(%CancelledError{} = error),
    do: error_map(:async_cancelled, error.message, error.details)

  defp error_map(type, message, details, fields \\ []) do
    type
    |> ExternalData.error_data(message, details, false, fields)
    |> ExternalData.to_map()
  end

  defp normalize_details(details) when is_map(details) and not is_struct(details), do: details

  defp normalize_details(details) when is_list(details),
    do: if(Keyword.keyword?(details), do: Map.new(details), else: %{})

  defp normalize_details(_details), do: %{}
end

defimpl JSON.Encoder,
  for: [
    Jido.Exec.Error.InvalidHandleError,
    Jido.Exec.Error.AsyncTimeoutError,
    Jido.Exec.Error.AsyncExecutionError,
    Jido.Exec.Error.CancelledError
  ] do
  def encode(error, opts) do
    error
    |> Jido.Exec.Error.to_map()
    |> JSON.Encoder.encode(opts)
  end
end
