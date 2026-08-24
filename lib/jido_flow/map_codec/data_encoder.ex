defmodule Jido.Flow.MapCodec.DataEncoder do
  @moduledoc false

  alias Jido.Flow.MapCodec.ErrorPath
  alias Jido.Flow.Registry

  @doc false
  def encode!(value, _path, _registry)
      when is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value),
      do: value

  def encode!(value, path, %Registry{} = registry) when is_atom(value) do
    %{"$type" => "atom", "value" => atom_identifier!(value, registry, path)}
  end

  def encode!(list, path, registry) when is_list(list) do
    if List.improper?(list) do
      ErrorPath.raise_validation("stored flow value is not JSON-safe", %{
        value: inspect(list),
        path: path
      })
    else
      list
      |> Enum.with_index()
      |> Enum.map(fn {value, index} -> encode!(value, path ++ [index], registry) end)
    end
  end

  def encode!(%{} = map, path, registry) when not is_struct(map) do
    %{
      "$type" => "map",
      "entries" =>
        map
        |> Enum.sort_by(fn {key, _value} -> key_sort_key(key) end)
        |> Enum.with_index()
        |> Enum.map(fn {{key, value}, index} ->
          %{
            "key" => encode_map_key!(key, path ++ [{:map_key, index}], registry),
            "value" => encode!(value, path ++ [{:map_value, index}], registry)
          }
        end)
    }
  end

  def encode!(%{__struct__: module}, path, _registry) do
    ErrorPath.raise_validation("stored flow value contains unsupported struct", %{
      struct: module,
      path: path
    })
  end

  def encode!(value, path, _registry) do
    ErrorPath.raise_validation("stored flow value is not JSON-safe", %{
      value: inspect(value),
      path: path
    })
  end

  @doc false
  def encode_map_key!(:__struct__, path, _registry) do
    ErrorPath.raise_validation("stored flow map key is reserved: :__struct__", %{
      record: :encoded_map,
      key: :__struct__,
      path: path
    })
  end

  def encode_map_key!(key, path, registry), do: encode_key!(key, path, registry)

  @doc false
  def encode_key!(key, registry), do: encode_key!(key, nil, registry)

  @doc false
  def key_sort_key(key) when is_atom(key), do: {0, Atom.to_string(key)}
  def key_sort_key(key) when is_binary(key), do: {1, key}
  def key_sort_key(key) when is_integer(key), do: {2, key}
  def key_sort_key(key), do: {3, inspect(key)}

  defp encode_key!(key, path, %Registry{} = registry) when is_atom(key) and not is_nil(key) do
    %{"type" => "atom", "value" => atom_identifier!(key, registry, path)}
  end

  defp encode_key!(key, _path, _registry) when is_binary(key),
    do: %{"type" => "string", "value" => key}

  defp encode_key!(key, _path, _registry) when is_integer(key),
    do: %{"type" => "integer", "value" => key}

  defp encode_key!(key, path, _registry) do
    details = %{key: inspect(key)}
    details = if is_list(path), do: Map.put(details, :path, path), else: details
    ErrorPath.raise_validation("stored flow map key is not JSON-safe", details)
  end

  defp atom_identifier!(atom, registry, path) do
    prefix = if is_list(path), do: path, else: []

    case Registry.identifier(registry, :atom, atom) |> ErrorPath.prepend(prefix) do
      {:ok, identifier} -> identifier
      {:error, error} -> raise error
    end
  end
end
