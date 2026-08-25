defmodule Jido.Flow.Reduce do
  @moduledoc """
  A named Flow fan-in operation over one ordered collection.

  A Reduce is one public Flow element. Its target calls form one serial left
  fold inside that element.

  This is a read-only canonical type. Create it through the Flow module DSL,
  `Jido.Flow.Builder`, or the stored Flow decoder.
  """

  alias Jido.Action.Error
  alias Jido.Flow.Component
  alias Jido.Flow.Expression

  @config_keys [:name, :collection, :initial, :action, :params, :after, :meta]

  @schema Zoi.struct(
            __MODULE__,
            %{
              name: Zoi.string(description: "Component name"),
              collection: Zoi.any(description: "Collection expression"),
              initial: Zoi.any(description: "Initial accumulator expression"),
              action: Zoi.atom(description: "Reducer Action module"),
              params: Zoi.any(description: "Reducer parameter expression") |> Zoi.default(%{}),
              after:
                Zoi.list(Zoi.string(), description: "Explicit control order") |> Zoi.default([]),
              meta: Zoi.map(description: "Portable author metadata") |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc false
  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, Exception.t()}
  def new(%__MODULE__{} = reduce), do: reduce |> Map.from_struct() |> new()

  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs), do: attrs |> Map.new() |> new(), else: invalid_configuration()
  end

  def new(%{} = attrs) do
    with :ok <- known_keys(attrs),
         {:ok, name} <- Component.name(Map.get(attrs, :name)),
         {:ok, collection} <-
           validate_required_expression(attrs, :collection, :reduce_collection),
         {:ok, initial} <- validate_required_expression(attrs, :initial, :reduce_initial),
         {:ok, action} <- Component.module(Map.get(attrs, :action), "reduce action"),
         {:ok, params} <- validate_params(Map.get(attrs, :params, %{})),
         {:ok, after_names} <- Component.after_names(Map.get(attrs, :after, [])),
         {:ok, meta} <- Component.meta(Map.get(attrs, :meta, %{})) do
      {:ok,
       %__MODULE__{
         name: name,
         collection: collection,
         initial: initial,
         action: action,
         params: params,
         after: after_names,
         meta: meta
       }}
    end
  end

  def new(_attrs), do: invalid_configuration()

  @doc false
  @spec new!(map() | keyword() | t()) :: t() | no_return()
  def new!(attrs) do
    case new(attrs) do
      {:ok, reduce} -> reduce
      {:error, error} -> raise error
    end
  end

  @doc false
  @spec result_deps(t()) :: [String.t()]
  def result_deps(%__MODULE__{} = reduce) do
    reduce.collection
    |> Expression.result_refs()
    |> Kernel.++(Expression.result_refs(reduce.initial))
    |> Kernel.++(Expression.result_refs(reduce.params))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc false
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = reduce) do
    %{
      kind: :reduce,
      name: reduce.name,
      collection: Expression.to_map(reduce.collection),
      initial: Expression.to_map(reduce.initial),
      action: reduce.action,
      params: Expression.to_map(reduce.params),
      after: reduce.after,
      meta: reduce.meta
    }
  end

  defp validate_required_expression(attrs, field, scope) do
    if Map.has_key?(attrs, field) do
      expression(Map.fetch!(attrs, field), scope)
    else
      {:error, Error.validation_error("reduce #{field} is required", %{path: [field]})}
    end
  end

  defp validate_params(nil), do: {:ok, %{}}

  defp validate_params(params), do: expression(params, :reduce_params)

  defp expression(value, scope) do
    with {:ok, value} <- Expression.normalize(value),
         :ok <- Expression.validate(value, scope) do
      {:ok, value}
    end
  end

  defp known_keys(attrs) do
    case Enum.find(Map.keys(attrs), &(&1 not in @config_keys)) do
      nil -> :ok
      key -> {:error, Error.validation_error("unknown reduce key: #{inspect(key)}")}
    end
  end

  defp invalid_configuration,
    do: {:error, Error.validation_error("reduce configuration must be a map", %{path: []})}
end
