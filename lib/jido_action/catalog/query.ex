defmodule Jido.Action.Catalog.Query do
  @moduledoc """
  Query value for filtering and searching an action catalog.
  """

  alias Jido.Action.Error

  @visibility_values [:public, :internal, :hidden]

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
    case Zoi.parse(@schema, attrs) do
      {:ok, query} ->
        {:ok, query}

      {:error, errors} ->
        {:error, Error.validation_error("Invalid catalog query", %{details: errors})}
    end
  end

  def new(_attrs), do: {:error, Error.validation_error("Invalid catalog query")}

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
