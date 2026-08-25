defmodule Jido.Flow.Subflow do
  @moduledoc "A named child Flow module in a canonical Flow."

  alias Jido.Flow.Error
  alias Jido.Flow.Component
  alias Jido.Flow.Expression

  @schema Zoi.struct(
            __MODULE__,
            %{
              name: Zoi.string(description: "Component name"),
              flow: Zoi.atom(description: "Jido Flow module"),
              params: Zoi.any(description: "Subflow parameter expression") |> Zoi.default(%{}),
              after:
                Zoi.list(Zoi.string(), description: "Explicit control order") |> Zoi.default([]),
              meta: Zoi.map(description: "Portable author metadata") |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @keys [:name, :flow, :params, :after, :meta]

  @doc "Builds and validates one canonical Subflow component."
  def new(%__MODULE__{} = subflow), do: subflow |> Map.from_struct() |> new()

  def new(attrs) when is_list(attrs),
    do: if(Keyword.keyword?(attrs), do: new(Map.new(attrs)), else: invalid())

  def new(%{} = attrs) do
    with :ok <- known_keys(attrs),
         {:ok, name} <- Component.name(Map.get(attrs, :name)),
         {:ok, flow} <- Component.module(Map.get(attrs, :flow), "subflow module"),
         {:ok, params} <- expression(Map.get(attrs, :params, %{})),
         {:ok, after_names} <- Component.after_names(Map.get(attrs, :after, [])),
         {:ok, meta} <- Component.meta(Map.get(attrs, :meta, %{})) do
      {:ok, %__MODULE__{name: name, flow: flow, params: params, after: after_names, meta: meta}}
    end
  end

  def new(_attrs), do: invalid()

  @doc "Builds one canonical Subflow or raises its validation error."
  def new!(attrs) do
    case new(attrs) do
      {:ok, subflow} -> subflow
      {:error, error} -> raise error
    end
  end

  def result_refs(%__MODULE__{params: params}), do: Expression.result_refs(params)

  defp expression(value) do
    with {:ok, value} <- Expression.normalize(value),
         :ok <- Expression.validate(value) do
      {:ok, value}
    end
  end

  defp known_keys(attrs) do
    case Enum.find(Map.keys(attrs), &(&1 not in @keys)) do
      nil -> :ok
      key -> {:error, Error.validation_error("unknown subflow key: #{inspect(key)}")}
    end
  end

  defp invalid, do: {:error, Error.validation_error("subflow configuration must be a map")}
end
