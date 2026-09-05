defmodule Jido.Action.Error.ExternalData do
  @moduledoc false

  @max_depth 16
  @max_items 64
  @max_nodes 1_024
  @max_bytes 4_096
  @max_integer Integer.pow(10, 100) - 1
  @truncated "#Truncated"
  @inspect_opts [charlists: :as_lists, structs: false, limit: 50, printable_limit: 1_024]

  # Only declared Flow causes use this marker. Other nested exceptions remain
  # opaque. Expand causes inside the shared traversal so they cannot reset its
  # depth or term budget, or convert already-encoded binaries a second time.
  defmodule NestedError do
    @moduledoc false
    defstruct [:error]

    @type t :: %__MODULE__{error: term()}
  end

  @doc false
  @spec error_data(atom(), term(), term(), boolean(), keyword()) :: map()
  def error_data(type, message, details, retryable?, fields \\ []) do
    %{
      type: type,
      message: if(is_binary(message), do: message, else: message(message)),
      details: detail_fields(details, fields),
      retryable?: retryable?
    }
  end

  @doc false
  @spec to_map(map()) :: map()
  def to_map(data) do
    %{data | message: message(data.message), details: details(data.details)}
  end

  @doc false
  @spec map_items(term(), (term() -> term())) :: term()
  def map_items(items, mapper) do
    case map_items(items, mapper, @max_items + 1) do
      {:ok, mapped} -> mapped
      :improper -> items
    end
  end

  defp map_items(_items, _mapper, 0), do: {:ok, []}
  defp map_items([], _mapper, _remaining), do: {:ok, []}

  defp map_items([head | tail], mapper, remaining) do
    case map_items(tail, mapper, remaining - 1) do
      {:ok, mapped} -> {:ok, [mapper.(head) | mapped]}
      :improper -> :improper
    end
  end

  defp map_items(_tail, _mapper, _remaining), do: :improper

  @doc false
  @spec details(term()) :: map()
  def details(value), do: value |> detail_map() |> value()

  defp detail_fields(value, fields) do
    fields
    |> Enum.reduce(detail_map(value), fn
      {_key, nil}, acc -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  defp detail_map(value) when is_map(value) and not is_struct(value), do: value

  defp detail_map(value) when is_list(value) do
    if bounded_keyword?(value, @max_items), do: Map.new(value), else: %{}
  end

  defp detail_map(_value), do: %{}

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

  defp convert(%NestedError{error: error}, depth, budget) do
    error
    |> Jido.Flow.Error.external_data()
    |> convert(depth, budget)
  end

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
    size = min(tuple_size(value), @max_items + 1)
    items = for index <- 0..(size - 1)//1, do: elem(value, index)
    list_items(items, depth + 1, budget, @max_items, [])
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
