defmodule Jido.Action.Error do
  @moduledoc """
  Defines and normalizes errors produced by Jido Actions.

  The public boundary is intentionally small. Concrete Action errors keep their
  canonical type, details, and retry policy. Any unsupported value becomes a
  non-retryable execution error with no structured details.

  Errors are non-retryable by default. Set `details.retry` to `true` only when
  another attempt is safe. Jido does not perform an automatic retry.
  """

  use Splode,
    error_classes: [
      invalid: __MODULE__.Invalid,
      execution: __MODULE__.Execution,
      config: __MODULE__.Config,
      internal: __MODULE__.Internal
    ],
    unknown_error: __MODULE__.Internal.UnknownError

  alias Jido.Action.Error.ExternalData

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

      @spec message(t()) :: String.t()
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

  Action, Flow, and Exec error maps and JSON use the same external conversion:

  - Atoms, numbers, Boolean values, and `nil` stay unchanged. JSON converts
    atoms to strings, except for Boolean values and `nil`.
  - Valid UTF-8 binaries stay unchanged. Other binaries become `base64:`
    strings. Binaries above 4,096 bytes become `"#Truncated<binary>"`.
  - Lists keep their order. Tuples become lists. Maps keep scalar keys;
    other keys become diagnostic strings. Map entries use Erlang term order.
    If converted keys collide, the last entry wins.
  - Structs, including exceptions, become `"#Struct<Module>"`. Valid Runic
    identities become full `runic:sha256:v1:...` strings.
  - PIDs, references, ports, functions, bitstrings, and short improper lists
    use inspected text. Inspection does not call custom struct protocols. It
    uses a limit of 50 entries and 1,024 printable characters. The binary limit
    also applies to the resulting text.
  - Conversion stops at depth 16 or after 1,024 terms per converted value.
    Map keys count toward this budget. Lists and tuples keep at most 64 items,
    with a final `"#Truncated"` marker when more items remain.
    Declared Flow causes keep their error maps and share the containing
    details' depth and term budget. They are converted once. Malformed cause
    lists use the same fallback as other unsupported diagnostic values.
  - A map above 64 entries becomes
    `%{"__truncated__" => "map exceeds 64 entries"}`. A map that exhausts the
    term budget uses the reserved `"__truncated__"` key. A depth or term limit
    replaces the affected value with `"#Truncated"`.
  - Integers with more than 100 decimal digits become `"#Truncated<integer>"`.
    Unsupported detail containers become an empty map. Direct keyword detail
    containers must have at most 64 entries.

  This conversion is lossy. It does not change the original exception, its
  details, or its stacktrace. The map omits the exception's top-level
  stacktrace. Use the in-memory error for full cause inspection. Diagnostic
  strings describe the current runtime; they are not persistent identifiers.
  """
  @spec to_map(term()) :: error_map()
  def to_map(error), do: error |> external_data() |> ExternalData.to_map()

  @doc false
  @spec external_data(term()) :: map()
  def external_data({:error, reason, _effects}), do: external_data(reason)
  def external_data({:error, reason}), do: external_data(reason)

  def external_data(%InvalidInputError{} = error) do
    ExternalData.error_data(:validation_error, error.message, error.details, false,
      field: error.field,
      value: error.value
    )
  end

  def external_data(%ExecutionFailureError{} = error) do
    ExternalData.error_data(:execution_error, error.message, error.details, retryable?(error))
  end

  def external_data(%TimeoutError{} = error) do
    ExternalData.error_data(:timeout, error.message, error.details, retryable?(error),
      timeout: error.timeout
    )
  end

  def external_data(%ConfigurationError{} = error) do
    ExternalData.error_data(:configuration_error, error.message, error.details, false)
  end

  def external_data(%InternalError{} = error) do
    ExternalData.error_data(:internal_error, error.message, error.details, false)
  end

  def external_data(%Internal.UnknownError{} = error) do
    message = if is_nil(error.error), do: error.message, else: error.error
    ExternalData.error_data(:internal_error, message, error.details, false)
  end

  def external_data(reason) do
    ExternalData.error_data(:execution_error, reason, %{}, false)
  end

  @doc """
  Returns whether a concrete Action error is retryable.

  A Boolean `details.retry` value controls the result for execution and timeout
  errors. All errors are non-retryable by default. Unsupported values are never
  retryable.
  """
  @spec retryable?(term()) :: boolean()
  def retryable?({:error, reason, _effects}), do: retryable?(reason)
  def retryable?({:error, reason}), do: retryable?(reason)
  def retryable?(%InvalidInputError{}), do: false
  def retryable?(%ConfigurationError{}), do: false
  def retryable?(%InternalError{}), do: false
  def retryable?(%Internal.UnknownError{}), do: false
  def retryable?(%TimeoutError{details: %{retry: retry}}) when is_boolean(retry), do: retry
  def retryable?(%TimeoutError{}), do: false

  def retryable?(%ExecutionFailureError{details: %{retry: retry}})
      when is_boolean(retry),
      do: retry

  def retryable?(%ExecutionFailureError{}), do: false
  def retryable?(_reason), do: false

  defp normalize_constructor_details(details)
       when is_map(details) and not is_struct(details),
       do: details

  defp normalize_constructor_details(details) when is_list(details) do
    if Keyword.keyword?(details), do: Map.new(details), else: %{}
  end

  defp normalize_constructor_details(_details), do: %{}
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
