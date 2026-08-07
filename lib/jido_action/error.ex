defmodule Jido.Action.Error do
  @moduledoc """
  Defines and normalizes errors produced by Jido Actions.

  The public boundary is intentionally small. Concrete Action errors keep their
  canonical type, details, and retry policy. Any unsupported value becomes a
  non-retryable execution error with no structured details.
  """

  use Splode,
    error_classes: [
      invalid: __MODULE__.Invalid,
      execution: __MODULE__.Execution,
      config: __MODULE__.Config,
      internal: __MODULE__.Internal
    ],
    unknown_error: __MODULE__.Internal.UnknownError

  @inspect_opts [charlists: :as_lists]

  @type details_input :: map() | keyword()
  @type error_map :: %{
          type: atom(),
          message: String.t(),
          details: map(),
          retryable?: boolean()
        }

  defmodule Invalid do
    @moduledoc false
    use Splode.ErrorClass, class: :invalid
  end

  defmodule Execution do
    @moduledoc false
    use Splode.ErrorClass, class: :execution
  end

  defmodule Config do
    @moduledoc false
    use Splode.ErrorClass, class: :config
  end

  defmodule Internal do
    @moduledoc false
    use Splode.ErrorClass, class: :internal

    defmodule UnknownError do
      @moduledoc false
      use Splode.Error,
        class: :internal,
        fields: [message: "Unknown error", error: nil, details: %{}]

      @type t :: %__MODULE__{
              message: String.t(),
              error: any() | nil,
              details: map()
            }

      def message(%{error: error}) when not is_nil(error), do: normalize_message(error)
      def message(%{message: message}), do: message

      defp normalize_message(message) when is_binary(message), do: message
      defp normalize_message(message) when is_atom(message), do: Atom.to_string(message)
      defp normalize_message(message), do: inspect(message)
    end
  end

  defmodule InvalidInputError do
    @moduledoc "Error for invalid input parameters."
    use Splode.Error,
      class: :invalid,
      fields: [message: "Invalid input", field: nil, value: nil, details: %{}]

    @type t :: %__MODULE__{
            message: String.t(),
            field: atom() | nil,
            value: any() | nil,
            details: map()
          }
  end

  defmodule ExecutionFailureError do
    @moduledoc "Error for Action execution failures."
    use Splode.Error,
      class: :execution,
      fields: [message: "Execution failed", details: %{}]

    @type t :: %__MODULE__{message: String.t(), details: map()}
  end

  defmodule TimeoutError do
    @moduledoc "Error for Action timeouts."
    use Splode.Error,
      class: :execution,
      fields: [message: "Action timed out", timeout: nil, details: %{}]

    @type t :: %__MODULE__{
            message: String.t(),
            timeout: non_neg_integer() | nil,
            details: map()
          }
  end

  defmodule ConfigurationError do
    @moduledoc "Error for invalid Action configuration."
    use Splode.Error,
      class: :config,
      fields: [message: "Configuration error", details: %{}]

    @type t :: %__MODULE__{message: String.t(), details: map()}
  end

  defmodule InternalError do
    @moduledoc "Error for unexpected internal failures."
    use Splode.Error,
      class: :internal,
      fields: [message: "Internal error", details: %{}]

    @type t :: %__MODULE__{message: String.t(), details: map()}
  end

  @doc "Creates an invalid-input error."
  @spec validation_error(String.t(), details_input()) :: InvalidInputError.t()
  def validation_error(message, details \\ %{}) do
    details = normalize_constructor_details(details)

    InvalidInputError.exception(
      message: message,
      field: Map.get(details, :field),
      value: Map.get(details, :value),
      details: details
    )
  end

  @doc "Creates an Action execution error."
  @spec execution_error(String.t(), details_input()) :: ExecutionFailureError.t()
  def execution_error(message, details \\ %{}) do
    ExecutionFailureError.exception(
      message: message,
      details: normalize_constructor_details(details)
    )
  end

  @doc "Creates an Action configuration error."
  @spec config_error(String.t(), details_input()) :: ConfigurationError.t()
  def config_error(message, details \\ %{}) do
    ConfigurationError.exception(
      message: message,
      details: normalize_constructor_details(details)
    )
  end

  @doc "Creates an Action timeout error."
  @spec timeout_error(String.t(), details_input()) :: TimeoutError.t()
  def timeout_error(message, details \\ %{}) do
    details = normalize_constructor_details(details)

    TimeoutError.exception(
      message: message,
      timeout: Map.get(details, :timeout),
      details: details
    )
  end

  @doc "Creates an internal Action error."
  @spec internal_error(String.t(), details_input()) :: InternalError.t()
  def internal_error(message, details \\ %{}) do
    InternalError.exception(
      message: message,
      details: normalize_constructor_details(details)
    )
  end

  @doc """
  Converts an Action error into its stable public map.

  Unsupported values become conservative execution errors. They cannot select
  a canonical type, add structured details, or request a retry.
  """
  @spec to_map(term()) :: error_map()
  def to_map({:error, reason, _effects}), do: to_map(reason)
  def to_map({:error, reason}), do: to_map(reason)

  def to_map(%InvalidInputError{} = error) do
    %{
      type: :validation_error,
      message: normalize_message(error.message),
      details:
        error.details
        |> normalize_details()
        |> maybe_put(:field, error.field)
        |> maybe_put(:value, normalize_detail_value(error.value)),
      retryable?: false
    }
  end

  def to_map(%ExecutionFailureError{} = error) do
    %{
      type: :execution_error,
      message: normalize_message(error.message),
      details: normalize_details(error.details),
      retryable?: retryable?(error)
    }
  end

  def to_map(%TimeoutError{} = error) do
    %{
      type: :timeout,
      message: normalize_message(error.message),
      details: error.details |> normalize_details() |> maybe_put(:timeout, error.timeout),
      retryable?: true
    }
  end

  def to_map(%ConfigurationError{} = error) do
    %{
      type: :configuration_error,
      message: normalize_message(error.message),
      details: normalize_details(error.details),
      retryable?: false
    }
  end

  def to_map(%InternalError{} = error) do
    %{
      type: :internal_error,
      message: normalize_message(error.message),
      details: normalize_details(error.details),
      retryable?: false
    }
  end

  def to_map(%Internal.UnknownError{} = error) do
    %{
      type: :internal_error,
      message: error |> Exception.message() |> normalize_message(),
      details: normalize_details(error.details),
      retryable?: false
    }
  end

  def to_map(reason) do
    %{
      type: :execution_error,
      message: normalize_message(reason),
      details: %{},
      retryable?: false
    }
  end

  @doc """
  Returns whether a concrete Action error has an explicit retry policy.

  Unsupported values are never retryable.
  """
  @spec retryable?(term()) :: boolean()
  def retryable?({:error, reason, _effects}), do: retryable?(reason)
  def retryable?({:error, reason}), do: retryable?(reason)
  def retryable?(%InvalidInputError{}), do: false
  def retryable?(%ConfigurationError{}), do: false
  def retryable?(%InternalError{}), do: false
  def retryable?(%Internal.UnknownError{}), do: false
  def retryable?(%TimeoutError{}), do: true

  def retryable?(%ExecutionFailureError{details: %{retry: retry}})
      when is_boolean(retry),
      do: retry

  def retryable?(%ExecutionFailureError{}), do: true
  def retryable?(_reason), do: false

  defp normalize_constructor_details(details)
       when is_map(details) and not is_struct(details),
       do: details

  defp normalize_constructor_details(details) when is_list(details) do
    if Keyword.keyword?(details), do: Map.new(details), else: %{}
  end

  defp normalize_constructor_details(_details), do: %{}

  defp normalize_message(message) when is_binary(message), do: json_safe_binary(message)
  defp normalize_message(message) when is_atom(message), do: Atom.to_string(message)
  defp normalize_message(message), do: safe_inspect(message)

  defp normalize_details(details) when is_map(details) and not is_struct(details) do
    Map.new(details, fn {key, value} ->
      {normalize_detail_key(key), normalize_detail_value(value)}
    end)
  end

  defp normalize_details(details) when is_list(details) do
    if Keyword.keyword?(details), do: details |> Map.new() |> normalize_details(), else: %{}
  end

  defp normalize_details(_details), do: %{}

  defp normalize_detail_value(value)
       when is_nil(value) or is_boolean(value) or is_number(value) or is_atom(value),
       do: value

  defp normalize_detail_value(value) when is_binary(value), do: json_safe_binary(value)
  defp normalize_detail_value(%_{} = value), do: "#Struct<#{inspect(value.__struct__)}>"
  defp normalize_detail_value(value) when is_map(value), do: normalize_details(value)

  defp normalize_detail_value(value) when is_list(value) do
    if proper_list?(value),
      do: Enum.map(value, &normalize_detail_value/1),
      else: safe_inspect(value)
  end

  defp normalize_detail_value(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&normalize_detail_value/1)
  end

  defp normalize_detail_value(value), do: safe_inspect(value)

  defp normalize_detail_key(key) when is_binary(key), do: json_safe_binary(key)

  defp normalize_detail_key(key)
       when is_atom(key) or is_number(key) or is_boolean(key) or is_nil(key),
       do: key

  defp normalize_detail_key(key), do: safe_inspect(key)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp proper_list?(list), do: proper_list_tail?(list)
  defp proper_list_tail?([]), do: true
  defp proper_list_tail?([_head | tail]), do: proper_list_tail?(tail)
  defp proper_list_tail?(_tail), do: false

  defp safe_inspect(value), do: inspect(value, @inspect_opts)

  defp json_safe_binary(value) do
    if String.valid?(value), do: value, else: "base64:" <> Base.encode64(value)
  end
end

defimpl JSON.Encoder,
  for: [
    Jido.Action.Error.InvalidInputError,
    Jido.Action.Error.ExecutionFailureError,
    Jido.Action.Error.TimeoutError,
    Jido.Action.Error.ConfigurationError,
    Jido.Action.Error.InternalError,
    Jido.Action.Error.Internal.UnknownError
  ] do
  def encode(error, opts) do
    error
    |> Jido.Action.Error.to_map()
    |> JSON.Encoder.encode(opts)
  end
end
