defmodule Jido.Flow.MapCodec.DataDecoder do
  @moduledoc false

  alias Jido.Flow.MapCodec.ErrorPath
  alias Jido.Flow.MapCodec.RecordValidator
  alias Jido.Flow.Registry

  @doc false
  def decode_optional(map, field, default, registry) do
    case Map.fetch(map, Atom.to_string(field)) do
      {:ok, value} -> decode(value, registry)
      :error -> {:ok, default}
    end
  end

  @doc false
  def decode(%{} = map, %Registry{} = registry) do
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
          Registry.resolve(registry, value, :atom)
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
             {:ok, entries} <- decode_entries(entries, &decode(&1, registry), registry) do
          {:ok, Map.new(entries)}
        end

      nil ->
        decode_plain_data_map(map, registry)

      type ->
        ErrorPath.error("unknown encoded value type: #{inspect(type)}", %{type: type})
    end
  end

  def decode(list, registry) when is_list(list) do
    if List.improper?(list) do
      stored_data_error(list)
    else
      list
      |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
        case decode(value, registry) do
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

  def decode(value, _registry)
      when is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value),
      do: {:ok, value}

  def decode(value, _registry), do: stored_data_error(value)

  @doc false
  def decode_entries(entries, value_decoder, registry) when is_list(entries) do
    if List.improper?(entries) do
      ErrorPath.error("encoded map entries must be a list", %{entries: inspect(entries)})
    else
      entries
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {entry, index}, {:ok, acc} ->
        case decode_entry(entry, value_decoder, registry, index) do
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

  def decode_entries(entries, _value_decoder, _registry) do
    ErrorPath.error("encoded map entries must be a list", %{entries: entries})
  end

  @doc false
  def decode_key(%{} = segment, registry) do
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
      decode_key(type, value, registry)
    end
  end

  def decode_key(segment, _registry) do
    ErrorPath.error("malformed flow path segment", %{segment: segment})
  end

  defp decode_plain_data_map(map, registry) do
    case Enum.find(Map.keys(map), &(not is_binary(&1))) do
      nil ->
        map
        |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
          case decode(value, registry) do
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

  defp decode_entry(%{} = entry, value_decoder, registry, index) do
    with :ok <-
           RecordValidator.validate_record(
             entry,
             ["key", "value"],
             ["key", "value"],
             :entry
           ),
         {:ok, key} <-
           RecordValidator.exact_fetch_required(entry, "key", "encoded map key is required"),
         {:ok, key} <-
           decode_map_key(key, registry) |> ErrorPath.prepend([{:map_key, index}]),
         {:ok, value} <-
           RecordValidator.exact_fetch_required(entry, "value", "encoded map value is required"),
         {:ok, value} <- value_decoder.(value) |> ErrorPath.prepend([{:map_value, index}]) do
      {:ok, {key, value}}
    end
  end

  defp decode_entry(entry, _value_decoder, _registry, _index) do
    ErrorPath.error("encoded map entry must be a map", %{entry: entry})
  end

  defp decode_key("atom", value, registry) when is_binary(value),
    do: Registry.resolve(registry, value, :atom)

  defp decode_key("string", value, _registry) when is_binary(value), do: {:ok, value}
  defp decode_key("integer", value, _registry) when is_integer(value), do: {:ok, value}

  defp decode_key(type, value, _registry) do
    ErrorPath.error("malformed flow path segment", %{type: type, value: value})
  end

  defp decode_map_key(segment, registry) do
    with {:ok, key} <- decode_key(segment, registry),
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

  defp stored_data_error(value) do
    ErrorPath.error("stored flow value is not JSON-safe", %{value: inspect(value)})
  end
end
