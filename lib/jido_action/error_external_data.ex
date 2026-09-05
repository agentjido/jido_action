defmodule Jido.Action.Error.ExternalData do
  @moduledoc false

  @max_depth 16
  @max_items 64
  @max_nodes 1_024
  @max_bytes 4_096
  @max_integer Integer.pow(10, 100) - 1
  @truncated "#Truncated"
  @inspect_opts [charlists: :as_lists, structs: false, limit: 50, printable_limit: 1_024]

  @doc false
  @spec details(term()) :: map()
  def details(value) when is_map(value) and not is_struct(value), do: value(value)

  def details(value) when is_list(value) do
    if bounded_keyword?(value, @max_items), do: value |> Map.new() |> details(), else: %{}
  end

  def details(_value), do: %{}

  @doc false
  @spec message(term()) :: String.t()
  def message(value) when is_binary(value), do: binary(value)
  def message(value) when is_atom(value), do: Atom.to_string(value)
  def message(value), do: safe_inspect(value)

  @doc false
  @spec value(term()) :: term()
  def value(value), do: value |> sanitize(0, @max_nodes) |> elem(0)

  defp sanitize(_value, _depth, budget) when budget <= 0, do: {@truncated, 0}

  defp sanitize(_value, depth, budget) when depth >= @max_depth,
    do: {@truncated, budget - 1}

  defp sanitize(value, depth, budget), do: convert(value, depth, budget - 1)

  defp convert(value, _depth, budget) when is_integer(value) and abs(value) > @max_integer,
    do: {"#Truncated<integer>", budget}

  defp convert(value, _depth, budget) when is_atom(value) or is_number(value),
    do: {value, budget}

  defp convert(value, _depth, budget) when is_binary(value), do: {binary(value), budget}

  defp convert(
         %Runic.Identity{scheme: :sha256, version: 1, domain: domain, digest: digest} = identity,
         _depth,
         budget
       )
       when is_atom(domain) and is_binary(digest) and byte_size(digest) == 32,
       do: {Runic.Identity.to_string(identity), budget}

  defp convert(%_{} = value, _depth, budget),
    do: {"#Struct<#{inspect(value.__struct__)}>", budget}

  defp convert(value, _depth, budget) when is_map(value) and map_size(value) > @max_items,
    do: {%{"__truncated__" => "map exceeds #{@max_items} entries"}, budget}

  defp convert(value, depth, budget) when is_map(value) do
    value
    |> Enum.sort()
    |> map_entries(depth + 1, budget, %{})
  end

  defp convert(value, depth, budget) when is_list(value) do
    case list_items(value, depth + 1, budget, @max_items, []) do
      {:improper, budget} -> {safe_inspect(value), budget}
      result -> result
    end
  end

  defp convert(value, depth, budget) when is_tuple(value) do
    size = min(tuple_size(value), @max_items)
    items = for index <- 0..(size - 1)//1, do: elem(value, index)
    {items, budget} = list_items(items, depth + 1, budget, @max_items, [])
    items = if tuple_size(value) > @max_items, do: items ++ [@truncated], else: items
    {items, budget}
  end

  defp convert(value, _depth, budget), do: {safe_inspect(value), budget}

  defp map_entries([], _depth, budget, acc), do: {acc, budget}

  defp map_entries(_entries, _depth, budget, acc) when budget <= 1,
    do: {Map.put(acc, "__truncated__", @truncated), 0}

  defp map_entries([{key, value} | rest], depth, budget, acc) do
    key = key(key)
    {value, budget} = sanitize(value, depth, budget - 1)
    map_entries(rest, depth, budget, Map.put(acc, key, value))
  end

  defp list_items([], _depth, budget, _remaining, acc), do: {Enum.reverse(acc), budget}

  defp list_items([_head | _tail], _depth, budget, remaining, acc)
       when budget <= 0 or remaining <= 0,
       do: {Enum.reverse([@truncated | acc]), budget}

  defp list_items([head | tail], depth, budget, remaining, acc) do
    {head, budget} = sanitize(head, depth, budget)
    list_items(tail, depth, budget, remaining - 1, [head | acc])
  end

  defp list_items(_tail, _depth, budget, _remaining, _acc), do: {:improper, budget}

  defp key(value) when is_binary(value), do: binary(value)
  defp key(value) when is_atom(value), do: value
  defp key(value) when is_number(value), do: value(value)
  defp key(%_{} = value), do: "#Struct<#{inspect(value.__struct__)}>"
  defp key(value), do: safe_inspect(value)

  defp bounded_keyword?([], _remaining), do: true

  defp bounded_keyword?([{key, _value} | tail], remaining) when is_atom(key) and remaining > 0,
    do: bounded_keyword?(tail, remaining - 1)

  defp bounded_keyword?(_value, _remaining), do: false

  defp safe_inspect(value), do: value |> inspect(@inspect_opts) |> binary()

  defp binary(value) when byte_size(value) > @max_bytes, do: "#Truncated<binary>"

  defp binary(value) do
    if String.valid?(value), do: value, else: "base64:" <> Base.encode64(value)
  end
end
