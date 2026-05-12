defmodule Jido.Action.Catalog.Query do
  @moduledoc """
  Query value for filtering and searching an action catalog.
  """

  alias Jido.Action.Error

  @visibility_values [:public, :internal, :hidden]
  @string_key_fields [
    :text,
    :namespace,
    :tags,
    :capabilities,
    :visibility,
    :limit,
    :filters,
    :metadata
  ]

  @schema Zoi.struct(
            __MODULE__,
            %{
              text: Zoi.string(description: "Search text") |> Zoi.optional(),
              namespace: Zoi.string(description: "Namespace filter") |> Zoi.optional(),
              tags: Zoi.list(Zoi.string(), description: "Required tags") |> Zoi.default([]),
              capabilities:
                Zoi.list(Zoi.string(), description: "Required capabilities") |> Zoi.default([]),
              visibility:
                Zoi.list(
                  Zoi.enum(@visibility_values),
                  description: "Allowed visibility values"
                )
                |> Zoi.default([:public]),
              limit:
                Zoi.integer(description: "Maximum hits to return")
                |> Zoi.min(1)
                |> Zoi.default(10),
              filters: Zoi.map(description: "Additional exact-match filters") |> Zoi.default(%{}),
              metadata: Zoi.map(description: "Arbitrary query metadata") |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc """
  Returns the Zoi schema used to validate catalog queries.
  """
  @spec schema() :: term()
  def schema, do: @schema

  @doc """
  Builds a catalog query.
  """
  @spec new(map() | keyword() | String.t() | t()) :: {:ok, t()} | {:error, Exception.t()}
  def new(%__MODULE__{} = query), do: {:ok, query}
  def new(text) when is_binary(text), do: new(%{text: text})
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(%{} = attrs) do
    attrs = normalize_attr_map(attrs)

    case Zoi.parse(@schema, attrs) do
      {:ok, query} ->
        {:ok, query}

      {:error, errors} ->
        {:error, Error.validation_error("Invalid catalog query", %{details: errors})}
    end
  end

  def new(_attrs), do: {:error, Error.validation_error("Invalid catalog query")}

  defp normalize_attr_map(attrs) do
    attrs
    |> normalize_known_string_keys()
    |> normalize_visibility()
  end

  defp normalize_known_string_keys(attrs) do
    Enum.reduce(@string_key_fields, attrs, fn key, acc ->
      maybe_rename(acc, Atom.to_string(key), key)
    end)
  end

  defp maybe_rename(attrs, from, to) do
    case Map.fetch(attrs, from) do
      {:ok, value} ->
        attrs
        |> Map.delete(from)
        |> Map.put_new(to, value)

      :error ->
        attrs
    end
  end

  defp normalize_visibility(%{visibility: values} = attrs) when is_list(values) do
    Map.put(attrs, :visibility, Enum.map(values, &normalize_visibility_value/1))
  end

  defp normalize_visibility(%{visibility: value} = attrs) do
    Map.put(attrs, :visibility, [normalize_visibility_value(value)])
  end

  defp normalize_visibility(attrs), do: attrs

  defp normalize_visibility_value(value) when is_binary(value) do
    Enum.find(@visibility_values, value, &(Atom.to_string(&1) == value))
  end

  defp normalize_visibility_value(value), do: value

  @doc """
  Same as `new/1`, but raises on error.
  """
  @spec new!(map() | keyword() | String.t() | t()) :: t() | no_return()
  def new!(attrs) do
    case new(attrs) do
      {:ok, query} -> query
      {:error, error} -> raise error
    end
  end
end
