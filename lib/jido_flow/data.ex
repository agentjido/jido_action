defmodule Jido.Flow.Data do
  @moduledoc """
  Advanced validation for portable literal and metadata data used by a
  `Jido.Flow`.

  Portable data contains JSON values plus existing atoms and non-string map
  keys that the trusted Flow Registry can encode. All strings must contain
  valid UTF-8 data.
  """

  alias Jido.Flow.Error

  @type scalar :: nil | boolean() | number() | String.t() | atom()
  @type key :: String.t() | non_neg_integer() | atom()
  @type t :: scalar() | [t()] | %{optional(key()) => t()}
  @type object :: %{optional(key()) => t()}

  @doc "Validates portable Flow data."
  @spec validate(term()) :: :ok | {:error, Error.InvalidDefinitionError.t()}
  def validate(value), do: validate(value, [])

  @doc "Validates a portable Flow metadata object."
  @spec validate_object(term()) :: :ok | {:error, Error.InvalidDefinitionError.t()}
  def validate_object(value) when is_map(value) and not is_struct(value), do: validate(value)

  def validate_object(_value) do
    {:error, Error.validation_error("flow metadata must be a portable map")}
  end

  @doc false
  @spec validate_key(term()) :: :ok | {:error, Error.InvalidDefinitionError.t()}
  def validate_key(key), do: validate_key(key, [])

  defp validate(value, _path_rev)
       when is_nil(value) or is_boolean(value) or is_integer(value) or is_float(value) or
              is_atom(value),
       do: :ok

  defp validate(value, path_rev) when is_binary(value) do
    if String.valid?(value),
      do: :ok,
      else: error("flow data strings must be valid UTF-8", path_rev)
  end

  defp validate(value, path_rev) when is_list(value) do
    if List.improper?(value) do
      error("flow data must contain proper lists", path_rev)
    else
      validate_list(value, path_rev, 0)
    end
  end

  defp validate(value, path_rev) when is_map(value) and not is_struct(value) do
    Enum.reduce_while(value, :ok, fn {key, item}, :ok ->
      with :ok <- validate_key(key, path_rev),
           :ok <- validate(item, [key | path_rev]) do
        {:cont, :ok}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp validate(value, path_rev) do
    {:error,
     Error.validation_error("flow data contains an unsupported value", %{
       path: Enum.reverse(path_rev),
       value_type: value_type(value)
     })}
  end

  defp validate_list([], _path_rev, _index), do: :ok

  defp validate_list([item | rest], path_rev, index) do
    with :ok <- validate(item, [index | path_rev]) do
      validate_list(rest, path_rev, index + 1)
    end
  end

  defp validate_key(key, path_rev) when is_binary(key), do: validate(key, path_rev)

  defp validate_key(key, _path_rev)
       when (is_integer(key) and key >= 0) or (is_atom(key) and not is_nil(key)),
       do: :ok

  defp validate_key(key, path_rev) do
    {:error,
     Error.validation_error("flow data contains an unsupported map key", %{
       path: Enum.reverse(path_rev),
       key: key
     })}
  end

  defp error(message, path_rev),
    do: {:error, Error.validation_error(message, %{path: Enum.reverse(path_rev)})}

  defp value_type(value) when is_tuple(value), do: :tuple
  defp value_type(value) when is_function(value), do: :function
  defp value_type(value) when is_pid(value), do: :pid
  defp value_type(value) when is_reference(value), do: :reference
  defp value_type(%{__struct__: module}), do: {:struct, module}
  defp value_type(_value), do: :other
end
