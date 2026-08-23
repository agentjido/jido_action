defmodule Jido.Flow.MapCodec.DataDecoder do
  @moduledoc false

  alias Jido.Flow.MapCodec.ErrorPath
  alias Jido.Flow.MapCodec.RecordValidator

  @doc false
  def decode_optional(map, field, default) do
    case Map.fetch(map, Atom.to_string(field)) do
      {:ok, value} -> decode(value)
      :error -> {:ok, default}
    end
  end

  @doc false
  def decode(%{} = map) do
    case Map.get(map, "$type") do
      "atom" ->
        with :ok <-
               RecordValidator.validate_record(
                 map,
                 ["$type", "value"],
                 ["$type", "value"],
                 :encoded_value
               ),
             {:ok, value} <-
               RecordValidator.exact_fetch_required(
                 map,
                 "value",
                 "encoded atom value is required"
               ),
             {:ok, value} <- decode_encoded_atom_value(value) do
          existing_atom(value)
        end

      "map" ->
        with :ok <-
               RecordValidator.validate_record(
                 map,
                 ["$type", "entries"],
                 ["$type", "entries"],
                 :encoded_map
               ),
             {:ok, entries} <-
               RecordValidator.exact_fetch_required(
                 map,
                 "entries",
                 "encoded map entries are required"
               ),
             {:ok, entries} <- decode_entries(entries, &decode/1) do
          {:ok, Map.new(entries)}
        end

      nil ->
        decode_plain_data_map(map)

      type ->
        ErrorPath.error("unknown encoded value type: #{inspect(type)}", %{type: type})
    end
  end

  def decode(list) when is_list(list) do
    if List.improper?(list) do
      stored_data_error(list)
    else
      list
      |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
        case decode(value) do
          {:ok, value} -> {:cont, {:ok, [value | acc]}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
      |> case do
        {:ok, values} -> {:ok, Enum.reverse(values)}
        {:error, error} -> {:error, error}
      end
    end
  end

  def decode(value)
      when is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value),
      do: {:ok, value}

  def decode(value), do: stored_data_error(value)

  @doc false
  def decode_entries(entries, value_decoder) when is_list(entries) do
    if List.improper?(entries) do
      ErrorPath.error("encoded map entries must be a list", %{entries: inspect(entries)})
    else
      entries
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {entry, index}, {:ok, acc} ->
        case decode_entry(entry, value_decoder, index) do
          {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
      |> case do
        {:ok, entries} ->
          entries |> Enum.reverse() |> RecordValidator.validate_unique_entries()

        {:error, error} ->
          {:error, error}
      end
    end
  end

  def decode_entries(entries, _value_decoder) do
    ErrorPath.error("encoded map entries must be a list", %{entries: entries})
  end

  @doc false
  def decode_key(%{} = segment) do
    with :ok <-
           RecordValidator.validate_record(
             segment,
             ["type", "value"],
             ["type", "value"],
             :typed_key
           ),
         {:ok, type} <-
           RecordValidator.exact_fetch_required(segment, "type", "typed key type is required"),
         {:ok, value} <-
           RecordValidator.exact_fetch_required(segment, "value", "typed key value is required") do
      decode_key(type, value)
    end
  end

  def decode_key(segment) do
    ErrorPath.error("malformed flow path segment", %{segment: segment})
  end

  defp decode_plain_data_map(map) do
    case Enum.find(Map.keys(map), &(not is_binary(&1))) do
      nil ->
        map
        |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
          case decode(value) do
            {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
            {:error, error} -> {:halt, {:error, error}}
          end
        end)

      key ->
        ErrorPath.error("stored plain data map contains a non-string key", %{
          record: :plain_data,
          key: key
        })
    end
  end

  defp decode_entry(%{} = entry, value_decoder, index) do
    with :ok <-
           RecordValidator.validate_record(
             entry,
             ["key", "value"],
             ["key", "value"],
             :entry
           ),
         {:ok, key} <-
           RecordValidator.exact_fetch_required(entry, "key", "encoded map key is required"),
         {:ok, key} <- decode_map_key(key) |> ErrorPath.prepend([{:map_key, index}]),
         {:ok, value} <-
           RecordValidator.exact_fetch_required(entry, "value", "encoded map value is required"),
         {:ok, value} <- value_decoder.(value) |> ErrorPath.prepend([{:map_value, index}]) do
      {:ok, {key, value}}
    end
  end

  defp decode_entry(entry, _value_decoder, _index) do
    ErrorPath.error("encoded map entry must be a map", %{entry: entry})
  end

  defp decode_key("atom", value) when is_binary(value), do: existing_atom(value)
  defp decode_key("string", value) when is_binary(value), do: {:ok, value}
  defp decode_key("integer", value) when is_integer(value), do: {:ok, value}

  defp decode_key(type, value) do
    ErrorPath.error("malformed flow path segment", %{type: type, value: value})
  end

  defp decode_map_key(segment) do
    with {:ok, key} <- decode_key(segment),
         :ok <- validate_decoded_map_key(key) do
      {:ok, key}
    end
  end

  defp validate_decoded_map_key(:__struct__) do
    ErrorPath.error("stored flow map key is reserved: :__struct__", %{
      record: :encoded_map,
      key: :__struct__,
      path: []
    })
  end

  defp validate_decoded_map_key(_key), do: :ok

  defp decode_encoded_atom_value(value) when is_binary(value), do: {:ok, value}

  defp decode_encoded_atom_value(value) do
    ErrorPath.error("encoded atom value must be a binary", %{value: value})
  end

  defp existing_atom(value) when is_binary(value) do
    {:ok, String.to_existing_atom(value)}
  rescue
    ArgumentError ->
      ErrorPath.error("unknown atom in flow map: #{inspect(value)}", %{value: value})
  end

  defp stored_data_error(value) do
    ErrorPath.error("stored flow value is not JSON-safe", %{value: inspect(value)})
  end
end
