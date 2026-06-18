defmodule Jido.Action.Error do
  @moduledoc """
  Centralized error handling for Jido Actions using Splode.

  This module provides a consistent way to create, aggregate, and handle errors
  within the Jido Action system. It uses the Splode library to enable error
  composition and classification.

  ## Structure & Naming

  This module has two kinds of submodules:

  * **Error classes** (for Splode): `Invalid`, `Execution`, `Config`, `Internal`.
    These are used internally by Splode for classification and aggregation.
    You generally should not raise or pattern match on these modules directly.

  * **Concrete exception structs** (ending in `Error`): `InvalidInputError`,
    `ExecutionFailureError`, `TimeoutError`, `ConfigurationError`, `InternalError`.
    These are the types you raise, rescue, and pattern match in application code.

  For cross-package handling, use `Jido.Action.Error.to_map/1` and match on the
  normalized `:type` atom. The public type set is intentionally small:
  `:validation_error`, `:configuration_error`, `:execution_error`, `:timeout`,
  and `:internal_error`. Domain-specific reasons are carried in `:details`,
  usually as `:kind` or `:reason`.

  ## Error Classes

  Errors are organized into the following classes, in order of precedence:

  - `:invalid` - Input validation, bad requests, and invalid configurations
  - `:execution` - Runtime execution errors and action failures
  - `:config` - System configuration and setup errors
  - `:internal` - Unexpected internal errors and system failures

  When multiple errors are aggregated, the class of the highest precedence error
  determines the overall error class.

  ## Usage

  Use this module to create and handle errors consistently:

      # Create a specific error
      {:error, error} = Jido.Action.Error.validation_error("must be a positive integer", field: :user_id)

      # Create timeout error
      {:error, timeout} = Jido.Action.Error.timeout_error("Action timed out after 30s", timeout: 30000)

      # Convert any value to a proper error
      {:error, normalized} = Jido.Action.Error.to_error("Something went wrong")
  """
  use Splode,
    # Error class modules for Splode
    error_classes: [
      invalid: Invalid,
      execution: Execution,
      config: Config,
      internal: Internal
    ],
    unknown_error: __MODULE__.Internal.UnknownError

  @canonical_error_types [
    :validation_error,
    :configuration_error,
    :execution_error,
    :timeout,
    :internal_error
  ]
  @inspect_opts [charlists: :as_lists, printable_limit: :infinity, limit: :infinity]

  # Error class modules for Splode - these are for classification/aggregation only.
  # Use the concrete exception structs (ending in `Error`) for raising/matching.

  defmodule Invalid do
    @moduledoc """
    Invalid input error class for Splode.

    This module is used by Splode to classify invalid-input errors when
    aggregating or analyzing multiple errors. Do not raise or match on this
    module directly — use `Jido.Action.Error.InvalidInputError` and helpers like
    `validation_error/2` instead.
    """
    use Splode.ErrorClass, class: :invalid
  end

  defmodule Execution do
    @moduledoc """
    Execution error class for Splode.

    This module is used by Splode to classify execution-related errors when
    aggregating or analyzing multiple errors. Do not raise or match on this
    module directly — use `Jido.Action.Error.ExecutionFailureError` and helpers like
    `execution_error/2` instead.
    """
    use Splode.ErrorClass, class: :execution
  end

  defmodule Config do
    @moduledoc """
    Configuration error class for Splode.

    This module is used by Splode to classify configuration-related errors when
    aggregating or analyzing multiple errors. Do not raise or match on this
    module directly — use `Jido.Action.Error.ConfigurationError` and helpers like
    `config_error/2` instead.
    """
    use Splode.ErrorClass, class: :config
  end

  defmodule Internal do
    @moduledoc """
    Internal error class for Splode.

    This module is used by Splode to classify internal/unexpected errors when
    aggregating or analyzing multiple errors. Do not raise or match on this
    module directly — use `Jido.Action.Error.InternalError` and helpers like
    `internal_error/2` instead.
    """
    use Splode.ErrorClass, class: :internal

    defmodule UnknownError do
      @moduledoc false
      # This module exists only to satisfy Splode's unknown_error requirement.
      defexception [:message, :details]

      @type t :: %__MODULE__{
              message: String.t(),
              details: map()
            }

      @impl true
      def exception(opts) do
        %__MODULE__{
          message: Keyword.get(opts, :message, "Unknown error"),
          details: Keyword.get(opts, :details, %{})
        }
      end
    end
  end

  # Define specific error structs inline
  defmodule InvalidInputError do
    @moduledoc "Error for invalid input parameters"
    defexception [:message, :field, :value, :details]

    @type t :: %__MODULE__{
            message: String.t(),
            field: atom() | nil,
            value: any() | nil,
            details: map()
          }

    @impl true
    def exception(opts) do
      message = Keyword.get(opts, :message, "Invalid input")

      %__MODULE__{
        message: message,
        field: Keyword.get(opts, :field),
        value: Keyword.get(opts, :value),
        details: Keyword.get(opts, :details, %{})
      }
    end
  end

  defmodule ExecutionFailureError do
    @moduledoc "Error for runtime execution failures"
    defexception [:message, :details]

    @type t :: %__MODULE__{
            message: String.t(),
            details: map()
          }

    @impl true
    def exception(opts) do
      %__MODULE__{
        message: Keyword.get(opts, :message, "Execution failed"),
        details: Keyword.get(opts, :details, %{})
      }
    end
  end

  defmodule TimeoutError do
    @moduledoc "Error for action timeouts"
    defexception [:message, :timeout, :details]

    @type t :: %__MODULE__{
            message: String.t(),
            timeout: non_neg_integer() | nil,
            details: map()
          }

    @impl true
    def exception(opts) do
      %__MODULE__{
        message: Keyword.get(opts, :message, "Action timed out"),
        timeout: Keyword.get(opts, :timeout),
        details: Keyword.get(opts, :details, %{})
      }
    end
  end

  defmodule ConfigurationError do
    @moduledoc "Error for configuration issues"
    defexception [:message, :details]

    @type t :: %__MODULE__{
            message: String.t(),
            details: map()
          }

    @impl true
    def exception(opts) do
      %__MODULE__{
        message: Keyword.get(opts, :message, "Configuration error"),
        details: Keyword.get(opts, :details, %{})
      }
    end
  end

  defmodule InternalError do
    @moduledoc "Error for unexpected internal failures"
    defexception [:message, :details]

    @type t :: %__MODULE__{
            message: String.t(),
            details: map()
          }

    @impl true
    def exception(opts) do
      %__MODULE__{
        message: Keyword.get(opts, :message, "Internal error"),
        details: Keyword.get(opts, :details, %{})
      }
    end
  end

  @doc """
  Creates a validation error for invalid input parameters.
  """
  @spec validation_error(String.t(), map()) :: InvalidInputError.t()
  def validation_error(message, details \\ %{}) do
    InvalidInputError.exception(
      message: message,
      field: details[:field],
      value: details[:value],
      details: details
    )
  end

  @doc """
  Creates an execution error for runtime failures.
  """
  @spec execution_error(String.t(), map()) :: ExecutionFailureError.t()
  def execution_error(message, details \\ %{}) do
    ExecutionFailureError.exception(
      message: message,
      details: details
    )
  end

  @doc """
  Creates a configuration error.
  """
  @spec config_error(String.t(), map()) :: ConfigurationError.t()
  def config_error(message, details \\ %{}) do
    ConfigurationError.exception(
      message: message,
      details: details
    )
  end

  @doc """
  Creates a timeout error.
  """
  @spec timeout_error(String.t(), map()) :: TimeoutError.t()
  def timeout_error(message, details \\ %{}) do
    TimeoutError.exception(
      message: message,
      timeout: details[:timeout],
      details: details
    )
  end

  @doc """
  Creates an internal server error.
  """
  @spec internal_error(String.t(), map()) :: InternalError.t()
  def internal_error(message, details \\ %{}) do
    InternalError.exception(
      message: message,
      details: details
    )
  end

  @type error_map :: %{
          type: atom(),
          message: String.t(),
          details: map(),
          retryable?: boolean()
        }

  @doc """
  Converts action-layer errors into a normalized plain map representation.

  This preserves the action error type and message while exposing a stable,
  serializable shape that downstream packages can adapt to their own domains.
  """
  @spec to_map(term()) :: error_map()
  def to_map({:error, reason, _effects}), do: to_map(reason)
  def to_map({:error, reason}), do: to_map(reason)

  def to_map(%{type: type, message: message} = error) when is_atom(type) do
    canonical_type = canonical_error_type(type)

    %{
      type: canonical_type,
      message: normalize_message(message),
      details:
        error
        |> Map.get(:details, %{})
        |> normalize_details()
        |> maybe_put_kind(type, canonical_type),
      retryable?: normalize_retryable(error, canonical_type)
    }
  end

  def to_map(%{code: type, message: message} = error) when is_atom(type) do
    canonical_type = canonical_error_type(type)

    %{
      type: canonical_type,
      message: normalize_message(message),
      details:
        error
        |> Map.get(:details, %{})
        |> normalize_details()
        |> maybe_put_kind(type, canonical_type),
      retryable?: normalize_retryable(error, canonical_type)
    }
  end

  def to_map(%InvalidInputError{
        message: message,
        field: field,
        value: value,
        details: details
      }) do
    %{
      type: :validation_error,
      message: normalize_message(message),
      details:
        details
        |> normalize_details()
        |> maybe_put(:field, field)
        |> maybe_put(:value, normalize_detail_value(value)),
      retryable?: false
    }
  end

  def to_map(%ExecutionFailureError{message: message, details: details}) do
    %{
      type: :execution_error,
      message: normalize_message(message),
      details: normalize_details(details),
      retryable?: execution_retryable?(details)
    }
  end

  def to_map(%TimeoutError{message: message, timeout: timeout, details: details}) do
    %{
      type: :timeout,
      message: normalize_message(message),
      details:
        details
        |> normalize_details()
        |> maybe_put(:timeout, timeout),
      retryable?: true
    }
  end

  def to_map(%ConfigurationError{message: message, details: details}) do
    %{
      type: :configuration_error,
      message: normalize_message(message),
      details: normalize_details(details),
      retryable?: false
    }
  end

  def to_map(%InternalError{message: message, details: details}) do
    %{
      type: :internal_error,
      message: normalize_message(message),
      details: normalize_details(details),
      retryable?: false
    }
  end

  def to_map(%Internal.UnknownError{message: message, details: details}) do
    %{
      type: :internal_error,
      message: normalize_message(message),
      details: normalize_details(details),
      retryable?: false
    }
  end

  def to_map(%{__struct__: module} = error)
      when is_atom(module) and
             module in [
               InvalidInputError,
               ExecutionFailureError,
               TimeoutError,
               ConfigurationError,
               InternalError,
               Internal.UnknownError
             ] do
    type = pseudo_struct_type(module)

    %{
      type: type,
      message: normalize_message(pseudo_struct_message(module, Map.get(error, :message))),
      details: normalize_pseudo_struct_details(error),
      retryable?: normalize_retryable(error, type)
    }
  end

  def to_map(%{message: message} = error) when not is_nil(message) do
    %{
      type: :execution_error,
      message: normalize_message(message),
      details: error |> extract_message_details() |> normalize_details(),
      retryable?: normalize_retryable(error, :execution_error)
    }
  end

  def to_map(reason) when is_atom(reason) do
    %{
      type: :execution_error,
      message: normalize_message(reason),
      details: %{reason: reason},
      retryable?: retryable?(reason)
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
  Returns whether the given action-layer error should be considered retryable.

  This is a conservative classification helper for adapters and integrations.
  Runtime retry decisions belong to Runic scheduler policy.
  """
  @spec retryable?(term()) :: boolean()
  def retryable?({:error, reason, _effects}), do: retryable?(reason)
  def retryable?({:error, reason}), do: retryable?(reason)
  def retryable?(%InvalidInputError{}), do: false
  def retryable?(%ConfigurationError{}), do: false
  def retryable?(%TimeoutError{}), do: true
  def retryable?(%ExecutionFailureError{details: details}), do: execution_retryable?(details)
  def retryable?(%InternalError{details: details}), do: retryable_hint(details, false)
  def retryable?(%Internal.UnknownError{details: details}), do: retryable_hint(details, false)

  def retryable?(%{retryable?: value}) when is_boolean(value), do: value
  def retryable?(%{retryable: value}) when is_boolean(value), do: value

  def retryable?(%{type: type} = error) when is_atom(type) do
    retryable_hint(Map.get(error, :details, error), default_retryable_type?(type))
  end

  def retryable?(%{code: type} = error) when is_atom(type) do
    retryable_hint(Map.get(error, :details, error), default_retryable_type?(type))
  end

  def retryable?(%{} = map) do
    retryable_hint(map, true)
  end

  def retryable?(reason) when is_atom(reason), do: retryable_hint(%{reason: reason}, false)
  def retryable?(_reason), do: true

  defp normalize_retryable(error, type) do
    cond do
      is_boolean(Map.get(error, :retryable?)) -> Map.get(error, :retryable?)
      is_boolean(Map.get(error, :retryable)) -> Map.get(error, :retryable)
      true -> retryable_hint(Map.get(error, :details, error), default_retryable_type?(type))
    end
  end

  defp normalize_message(message) when is_binary(message), do: message
  defp normalize_message(message) when is_atom(message), do: Atom.to_string(message)
  defp normalize_message(message), do: safe_inspect(message)

  defp normalize_details(details) when is_map(details) do
    case normalize_detail_value(details) do
      sanitized when is_map(sanitized) -> sanitized
      _ -> %{}
    end
  end

  defp normalize_details(details) when is_list(details) do
    if Keyword.keyword?(details) do
      details
      |> Enum.into(%{})
      |> normalize_details()
    else
      %{}
    end
  end

  defp normalize_details(_details), do: %{}

  defp normalize_pseudo_struct_details(error) when is_map(error) do
    base_details =
      error
      |> Map.get(:details, %{})
      |> normalize_details()

    extra_details =
      error
      |> Map.drop([:message, :details, :__struct__, :__exception__])
      |> normalize_details()

    Map.merge(base_details, extra_details)
  end

  defp extract_message_details(%_{} = error) do
    error
    |> Map.from_struct()
    |> Map.drop([:__exception__, :message])
  end

  defp extract_message_details(%{} = error) do
    Map.drop(error, [:message, :__struct__, :__exception__])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_kind(map, original_type, canonical_type) do
    if original_type in @canonical_error_types or canonical_type != :execution_error do
      map
    else
      Map.put_new(map, :kind, original_type)
    end
  end

  defp canonical_error_type(type) when type in @canonical_error_types, do: type
  defp canonical_error_type(:config_error), do: :configuration_error
  defp canonical_error_type(:invalid_input), do: :validation_error
  defp canonical_error_type(:invalid_input_error), do: :validation_error
  defp canonical_error_type(:timeout_error), do: :timeout
  defp canonical_error_type(:execution_failure), do: :execution_error
  defp canonical_error_type(:execution_failure_error), do: :execution_error
  defp canonical_error_type(:internal), do: :internal_error
  defp canonical_error_type(_type), do: :execution_error

  defp default_retryable_type?(type)
       when type in [:validation_error, :configuration_error, :internal_error],
       do: false

  defp default_retryable_type?(:timeout), do: true
  defp default_retryable_type?(:execution_error), do: true
  defp default_retryable_type?(_type), do: true

  defp retryable_hint(term, default) do
    case extract_retry_hint(term) do
      nil -> default
      value -> value != false
    end
  end

  defp execution_retryable?(%{reason: reason} = details) when is_atom(reason) do
    retryable_hint(details, false)
  end

  defp execution_retryable?(%{"reason" => reason} = details) when is_atom(reason) do
    retryable_hint(details, false)
  end

  defp execution_retryable?(details), do: retryable_hint(details, true)

  defp extract_retry_hint(%{details: details}) do
    case extract_retry_value(details) do
      nil -> extract_retry_hint(details)
      value -> value
    end
  end

  defp extract_retry_hint(%{} = map) do
    case extract_retry_value(map) do
      nil -> map |> extract_nested_reason() |> extract_retry_hint()
      value -> value
    end
  end

  defp extract_retry_hint(keyword) when is_list(keyword) do
    if Keyword.keyword?(keyword) do
      case extract_retry_value(keyword) do
        nil -> keyword |> Keyword.get(:reason) |> extract_retry_hint()
        value -> value
      end
    end
  end

  defp extract_retry_hint(_), do: nil

  defp extract_nested_reason(%{reason: reason}), do: reason
  defp extract_nested_reason(%{"reason" => reason}), do: reason
  defp extract_nested_reason(_), do: nil

  defp extract_retry_value(%{} = map) do
    cond do
      Map.has_key?(map, :retry) -> Map.get(map, :retry)
      Map.has_key?(map, "retry") -> Map.get(map, "retry")
      true -> nil
    end
  end

  defp extract_retry_value(keyword) when is_list(keyword) do
    if Keyword.keyword?(keyword), do: Keyword.get(keyword, :retry), else: nil
  end

  defp extract_retry_value(_), do: nil

  defp pseudo_struct_type(InvalidInputError), do: :validation_error
  defp pseudo_struct_type(ExecutionFailureError), do: :execution_error
  defp pseudo_struct_type(TimeoutError), do: :timeout
  defp pseudo_struct_type(ConfigurationError), do: :configuration_error
  defp pseudo_struct_type(InternalError), do: :internal_error
  defp pseudo_struct_type(Internal.UnknownError), do: :internal_error

  defp pseudo_struct_message(_module, message) when not is_nil(message), do: message
  defp pseudo_struct_message(InvalidInputError, nil), do: "Invalid input"
  defp pseudo_struct_message(ExecutionFailureError, nil), do: "Execution failed"
  defp pseudo_struct_message(TimeoutError, nil), do: "Action timed out"
  defp pseudo_struct_message(ConfigurationError, nil), do: "Configuration error"
  defp pseudo_struct_message(InternalError, nil), do: "Internal error"
  defp pseudo_struct_message(Internal.UnknownError, nil), do: "Unknown error"

  defp safe_inspect(value) do
    inspect(value)
  rescue
    _ ->
      value
      |> normalize_detail_value()
      |> inspect()
  end

  defp normalize_detail_value(value)

  defp normalize_detail_value(value)
       when is_nil(value) or is_boolean(value) or is_number(value) or is_atom(value) or
              is_binary(value),
       do: value

  defp normalize_detail_value(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> normalize_detail_map()
    |> Map.put(:__struct__, normalize_struct_marker(struct.__struct__))
    |> maybe_put_exception_marker(struct)
  end

  defp normalize_detail_value(value) when is_map(value), do: normalize_detail_map(value)

  defp normalize_detail_value(value) when is_list(value) do
    case list_parts(value) do
      {:proper, items} ->
        Enum.map(items, &normalize_detail_value/1)

      {:improper, items, tail} ->
        %{
          __type__: :improper_list,
          items: Enum.map(items, &normalize_detail_value/1),
          tail: normalize_detail_value(tail)
        }
    end
  end

  defp normalize_detail_value(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&normalize_detail_value/1)
  end

  defp normalize_detail_value(value) when is_pid(value),
    do: List.to_string(:erlang.pid_to_list(value))

  defp normalize_detail_value(value) when is_reference(value),
    do: List.to_string(:erlang.ref_to_list(value))

  defp normalize_detail_value(value) when is_port(value),
    do: List.to_string(:erlang.port_to_list(value))

  defp normalize_detail_value(value), do: inspect_detail_value(value)

  defp normalize_detail_map(map) do
    map
    |> Map.to_list()
    |> Enum.map(fn {key, value} ->
      normalized_key = normalize_detail_key(key)
      {normalized_key, inspect_detail_value(normalized_key), normalize_detail_value(value)}
    end)
    |> Enum.sort_by(fn {_normalized_key, sort_key, _normalized_value} -> sort_key end)
    |> Enum.map(fn {normalized_key, _sort_key, normalized_value} ->
      {normalized_key, normalized_value}
    end)
    |> Map.new()
  end

  defp normalize_detail_key(key)
       when is_atom(key) or is_binary(key) or is_number(key) or is_boolean(key) or is_nil(key),
       do: key

  defp normalize_detail_key(key) do
    key
    |> normalize_detail_value()
    |> inspect_detail_key()
  end

  defp inspect_detail_key(key) when is_binary(key), do: key
  defp inspect_detail_key(key) when is_atom(key), do: Atom.to_string(key)
  defp inspect_detail_key(key) when is_number(key) or is_boolean(key), do: to_string(key)
  defp inspect_detail_key(key), do: inspect_detail_value(key)

  defp maybe_put_exception_marker(map, struct) do
    if is_exception(struct) do
      Map.put(map, :__exception__, true)
    else
      map
    end
  end

  defp normalize_struct_marker(mod) when is_atom(mod), do: inspect(mod)

  defp inspect_detail_value(value) do
    inspect(value, @inspect_opts)
  rescue
    _ -> fallback_detail_inspect(value)
  end

  defp fallback_detail_inspect(value) when is_function(value), do: "#Function<uninspectable>"

  defp fallback_detail_inspect(value) when is_pid(value),
    do: List.to_string(:erlang.pid_to_list(value))

  defp fallback_detail_inspect(value) when is_reference(value),
    do: List.to_string(:erlang.ref_to_list(value))

  defp fallback_detail_inspect(value) when is_port(value),
    do: List.to_string(:erlang.port_to_list(value))

  defp fallback_detail_inspect(%_{} = struct) do
    "#Struct<#{normalize_struct_marker(struct.__struct__)}>"
  end

  defp fallback_detail_inspect(value) when is_map(value), do: "#Map<size=#{map_size(value)}>"

  defp fallback_detail_inspect(value) when is_list(value) do
    case list_parts(value) do
      {:proper, items} ->
        "#List<size=#{length(items)}>"

      {:improper, items, tail} ->
        "#ImproperList<size=#{length(items)}, tail=#{inspect_detail_value(tail)}>"
    end
  end

  defp fallback_detail_inspect(value) when is_tuple(value),
    do: "#Tuple<size=#{tuple_size(value)}>"

  defp fallback_detail_inspect(value) when is_binary(value), do: value
  defp fallback_detail_inspect(value) when is_atom(value), do: Atom.to_string(value)
  defp fallback_detail_inspect(value) when is_number(value), do: to_string(value)
  defp fallback_detail_inspect(value) when is_boolean(value), do: to_string(value)
  defp fallback_detail_inspect(nil), do: "nil"
  defp fallback_detail_inspect(_value), do: "#Term<uninspectable>"

  defp list_parts(list), do: do_list_parts(list, [])

  defp do_list_parts([], acc), do: {:proper, Enum.reverse(acc)}
  defp do_list_parts([head | tail], acc), do: do_list_parts(tail, [head | acc])
  defp do_list_parts(tail, acc), do: {:improper, Enum.reverse(acc), tail}
end

defimpl Jason.Encoder,
  for: [
    Jido.Action.Error.InvalidInputError,
    Jido.Action.Error.ExecutionFailureError,
    Jido.Action.Error.TimeoutError,
    Jido.Action.Error.ConfigurationError,
    Jido.Action.Error.InternalError,
    Jido.Action.Error.Internal.UnknownError
  ] do
  def encode(error, opts) when is_map(error) do
    error
    |> Jido.Action.Error.to_map()
    |> Jason.Encode.map(opts)
  end
end
