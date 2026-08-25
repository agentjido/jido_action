defmodule Jido.Flow.Data do
  @moduledoc """
  Validates portable literal and metadata data used by a `Jido.Flow`.

  Portable data contains JSON values plus existing atoms and non-string map
  keys that the trusted Flow Registry can encode.
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

  defp validate(value, _path)
       when is_nil(value) or is_boolean(value) or is_integer(value) or is_float(value) or
              is_binary(value) or is_atom(value),
       do: :ok

  defp validate(value, path) when is_list(value) do
    if List.improper?(value) do
      error("flow data must contain proper lists", path)
    else
      value
      |> Enum.with_index()
      |> Enum.reduce_while(:ok, fn {item, index}, :ok ->
        case validate(item, path ++ [index]) do
          :ok -> {:cont, :ok}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
    end
  end

  defp validate(value, path) when is_map(value) and not is_struct(value) do
    Enum.reduce_while(value, :ok, fn {key, item}, :ok ->
      with :ok <- validate_key(key, path),
           :ok <- validate(item, path ++ [key]) do
        {:cont, :ok}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp validate(value, path) do
    {:error,
     Error.validation_error("flow data contains an unsupported value", %{
       path: path,
       value_type: value_type(value)
     })}
  end

  defp validate_key(key, _path)
       when is_binary(key) or (is_integer(key) and key >= 0) or
              (is_atom(key) and not is_nil(key)),
       do: :ok

  defp validate_key(key, path) do
    {:error,
     Error.validation_error("flow data contains an unsupported map key", %{
       path: path,
       key: key
     })}
  end

  defp error(message, path), do: {:error, Error.validation_error(message, %{path: path})}

  defp value_type(value) when is_tuple(value), do: :tuple
  defp value_type(value) when is_function(value), do: :function
  defp value_type(value) when is_pid(value), do: :pid
  defp value_type(value) when is_reference(value), do: :reference
  defp value_type(%{__struct__: module}), do: {:struct, module}
  defp value_type(_value), do: :other
end
