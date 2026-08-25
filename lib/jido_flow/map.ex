defmodule Jido.Flow.Map do
  @moduledoc """
  A named Flow fan-out operation over one ordered collection.

  A Map is one canonical authoring component. Native execution exposes its
  Runic FanOut, item, FanIn, and output work. Create it with `new/1`, the Flow
  module DSL, `Jido.Flow.Builder`, or `Jido.Flow.Codec`.
  """

  alias Jido.Flow.Error
  alias Jido.Flow.Component
  alias Jido.Flow.Expression

  @config_keys [:name, :collection, :action, :params, :on_error, :after, :meta]

  @schema Zoi.struct(
            __MODULE__,
            %{
              name: Zoi.string(description: "Component name"),
              collection: Zoi.any(description: "Collection expression"),
              action: Zoi.atom(description: "Item Action module"),
              params: Zoi.any(description: "Item parameter expression") |> Zoi.default(%{}),
              on_error:
                Zoi.enum([:fail_fast, :collect_errors], description: "Map error mode")
                |> Zoi.default(:fail_fast),
              after:
                Zoi.list(Zoi.string(), description: "Explicit control order") |> Zoi.default([]),
              meta: Zoi.map(description: "Portable author metadata") |> Zoi.default(%{})
            },
            coerce: true
          )

  @type error_mode :: :fail_fast | :collect_errors
  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Builds and validates one canonical Map component."
  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, Exception.t()}
  def new(%__MODULE__{} = map), do: map |> Map.from_struct() |> new()

  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs), do: attrs |> Map.new() |> new(), else: invalid_configuration()
  end

  def new(%{} = attrs) do
    with :ok <- known_keys(attrs),
         {:ok, name} <- Component.name(Map.get(attrs, :name)),
         {:ok, collection} <- validate_required_expression(attrs, :collection, :map_collection),
         {:ok, action} <- Component.module(Map.get(attrs, :action), "map action"),
         {:ok, params} <- validate_params(Map.get(attrs, :params, %{})),
         {:ok, on_error} <- validate_on_error(Map.get(attrs, :on_error, :fail_fast)),
         {:ok, after_names} <- Component.after_names(Map.get(attrs, :after, [])),
         {:ok, meta} <- Component.meta(Map.get(attrs, :meta, %{})) do
      {:ok,
       %__MODULE__{
         name: name,
         collection: collection,
         action: action,
         params: params,
         on_error: on_error,
         after: after_names,
         meta: meta
       }}
    end
  end

  def new(_attrs), do: invalid_configuration()

  @doc "Builds one canonical Map component or raises its validation error."
  @spec new!(map() | keyword() | t()) :: t() | no_return()
  def new!(attrs) do
    case new(attrs) do
      {:ok, map} -> map
      {:error, error} -> raise error
    end
  end

  @doc false
  @spec result_deps(t()) :: [String.t()]
  def result_deps(%__MODULE__{} = map) do
    map.collection
    |> Expression.result_refs()
    |> Kernel.++(Expression.result_refs(map.params))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc false
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = map) do
    %{
      kind: :map,
      name: map.name,
      collection: Expression.to_map(map.collection),
      action: map.action,
      params: Expression.to_map(map.params),
      on_error: map.on_error,
      after: map.after,
      meta: map.meta
    }
  end

  defp validate_required_expression(attrs, field, scope) do
    if Map.has_key?(attrs, field) do
      expression(Map.fetch!(attrs, field), scope)
    else
      {:error, Error.validation_error("map #{field} is required", %{path: [field]})}
    end
  end

  defp validate_params(nil), do: {:ok, %{}}

  defp validate_params(params), do: expression(params, :map_params)

  defp expression(value, scope) do
    with {:ok, value} <- Expression.normalize(value),
         :ok <- Expression.validate(value, scope) do
      {:ok, value}
    end
  end

  defp known_keys(attrs) do
    case Enum.find(Map.keys(attrs), &(&1 not in @config_keys)) do
      nil -> :ok
      key -> {:error, Error.validation_error("unknown map key: #{inspect(key)}")}
    end
  end

  defp validate_on_error(on_error) when on_error in [:fail_fast, :collect_errors],
    do: {:ok, on_error}

  defp validate_on_error(on_error) do
    {:error,
     Error.validation_error("map on_error must be :fail_fast or :collect_errors", %{
       path: [:on_error],
       on_error: on_error
     })}
  end

  defp invalid_configuration,
    do: {:error, Error.validation_error("map configuration must be a map", %{path: []})}
end
