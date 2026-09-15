defmodule Jido.Flow.Subflow do
  @moduledoc "A named child Flow module in a canonical Flow."

  alias Jido.Flow.Error
  alias Jido.Flow.Component.Fields
  alias Jido.Flow.Expression

  @schema Zoi.struct(
            __MODULE__,
            %{
              name: Zoi.string(description: "Component name"),
              flow: Zoi.atom(description: "Jido Flow module"),
              params: Zoi.any(description: "Subflow parameter expression") |> Zoi.default(%{}),
              needs:
                Zoi.list(Zoi.string(), description: "Explicit control dependencies")
                |> Zoi.default([]),
              meta: Zoi.map(description: "Portable author metadata") |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @keys [:name, :flow, :params, :needs, :meta]

  @doc "Builds and validates one canonical Subflow component."
  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, Exception.t()}
  def new(%__MODULE__{} = subflow), do: subflow |> Map.from_struct() |> new()

  def new(attrs) when is_list(attrs),
    do: if(Keyword.keyword?(attrs), do: new(Map.new(attrs)), else: invalid())

  def new(%{} = attrs) do
    with :ok <- known_keys(attrs),
         {:ok, name} <- Fields.name(Map.get(attrs, :name)),
         {:ok, flow} <- Fields.module(Map.get(attrs, :flow), "subflow module"),
         {:ok, params} <- Expression.prepare(Map.get(attrs, :params, %{})),
         {:ok, needs_names} <- Fields.needs_names(Map.get(attrs, :needs, [])),
         {:ok, meta} <- Fields.meta(Map.get(attrs, :meta, %{})) do
      {:ok, %__MODULE__{name: name, flow: flow, params: params, needs: needs_names, meta: meta}}
    end
  end

  def new(_attrs), do: invalid()

  @doc "Builds one canonical Subflow or raises its validation error."
  @spec new!(map() | keyword() | t()) :: t() | no_return()
  def new!(attrs) do
    case new(attrs) do
      {:ok, subflow} -> subflow
      {:error, error} -> raise error
    end
  end

  @doc false
  @spec result_refs(t()) :: [String.t()]
  def result_refs(%__MODULE__{params: params}), do: Expression.result_refs(params)

  defp known_keys(attrs) do
    case Enum.reject(Map.keys(attrs), &(&1 in @keys)) do
      [] -> :ok
      [key | _rest] -> {:error, Error.validation_error("unknown subflow key: #{inspect(key)}")}
    end
  end

  defp invalid, do: {:error, Error.validation_error("subflow configuration must be a map")}
end
