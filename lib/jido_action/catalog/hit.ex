defmodule Jido.Action.Catalog.Hit do
  @moduledoc """
  Ranked search hit returned from an action catalog query.
  """

  alias Jido.Action.Error

  @schema Zoi.struct(
            __MODULE__,
            %{
              entry: Zoi.any(description: "Catalog entry"),
              score: Zoi.float(description: "Deterministic lexical score") |> Zoi.default(0.0),
              reason: Zoi.string(description: "Short match reason") |> Zoi.optional(),
              matches: Zoi.map(description: "Matched fields") |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc """
  Returns the Zoi schema used to validate catalog hits.
  """
  @spec schema() :: term()
  def schema, do: @schema

  @doc """
  Builds a catalog hit.
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Exception.t()}
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(%{} = attrs) do
    attrs = Map.reject(attrs, fn {_key, value} -> is_nil(value) end)

    case Zoi.parse(@schema, attrs) do
      {:ok, hit} ->
        {:ok, hit}

      {:error, errors} ->
        {:error, Error.validation_error("Invalid catalog hit", %{details: errors})}
    end
  end

  def new(_attrs), do: {:error, Error.validation_error("Invalid catalog hit")}

  @doc """
  Same as `new/1`, but raises on error.
  """
  @spec new!(map() | keyword()) :: t() | no_return()
  def new!(attrs) do
    case new(attrs) do
      {:ok, hit} -> hit
      {:error, error} -> raise error
    end
  end
end
