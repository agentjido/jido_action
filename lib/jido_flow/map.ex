defmodule Jido.Flow.Map do
  @moduledoc """
  A named Flow fan-out operation over one ordered collection.

  A Map is one public Flow element. Item work is internal to that element.
  This is a read-only canonical type. Create it through the Flow module DSL,
  `Jido.Flow.Builder`, or the stored Flow decoder.
  """

  alias Jido.Action.Error
  alias Jido.Flow.Element.Validation, as: ElementValidation
  alias Jido.Flow.Expression
  alias Jido.Instruction

  @config_keys [:name, :collection, :action, :input, :on_error, :deps, :provenance]

  @type error_mode :: :fail_fast | :collect_errors
  @type t :: %__MODULE__{
          name: String.t(),
          collection: term(),
          action: module(),
          input: term(),
          on_error: error_mode(),
          deps: [String.t()],
          provenance: map()
        }

  @enforce_keys @config_keys
  defstruct @config_keys

  @doc false
  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, Exception.t()}
  def new(%__MODULE__{} = map), do: map |> Map.from_struct() |> new()

  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs), do: attrs |> Map.new() |> new(), else: invalid_configuration()
  end

  def new(%{} = attrs) do
    with :ok <- ElementValidation.known_keys(attrs, @config_keys, "map"),
         {:ok, name} <- ElementValidation.name(Map.get(attrs, :name), :map),
         {:ok, collection} <- validate_required_expression(attrs, :collection, :map_collection),
         {:ok, action} <- ElementValidation.target(Map.get(attrs, :action), :map, [:action]),
         {:ok, input} <- validate_input(Map.get(attrs, :input, %{})),
         {:ok, on_error} <- validate_on_error(Map.get(attrs, :on_error, :fail_fast)),
         {:ok, deps} <- ElementValidation.deps(Map.get(attrs, :deps, []), :map),
         {:ok, provenance} <-
           ElementValidation.provenance(Map.get(attrs, :provenance, %{}), :map) do
      {:ok,
       %__MODULE__{
         name: name,
         collection: collection,
         action: action,
         input: input,
         on_error: on_error,
         deps: deps,
         provenance: provenance
       }}
    end
  end

  def new(_attrs), do: invalid_configuration()

  @doc false
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
    |> Kernel.++(Expression.result_refs(map.input))
    |> Kernel.++(map.deps)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc false
  @spec put_deps(t(), [String.t()]) :: t()
  def put_deps(%__MODULE__{} = map, deps), do: %{map | deps: deps}

  @doc false
  @spec check(t()) :: :ok | {:error, Exception.t()}
  def check(%__MODULE__{} = map) do
    case Instruction.validate_action_contract(map.action) do
      :ok ->
        :ok

      {:error, error} ->
        {:error,
         Error.validation_error(
           error.message,
           error.details |> Map.merge(%{map: map.name, target: map.action})
         )}
    end
  end

  @doc false
  @spec to_map(t(), keyword()) :: map()
  def to_map(%__MODULE__{} = map, opts \\ []) do
    base = %{
      kind: :map,
      name: map.name,
      collection: Expression.to_map(map.collection),
      action: map.action,
      input: Expression.to_map(map.input),
      on_error: map.on_error,
      deps: Enum.sort(map.deps)
    }

    if Keyword.get(opts, :provenance, false) do
      Map.put(base, :provenance, map.provenance)
    else
      base
    end
  end

  @doc false
  @spec static_data(t()) :: map()
  def static_data(%__MODULE__{} = map) do
    %{
      kind: :map,
      name: map.name,
      collection: map.collection,
      action: map.action,
      input: map.input,
      on_error: map.on_error,
      deps: map.deps
    }
  end

  @doc false
  @spec semantic_data(t()) :: map()
  def semantic_data(%__MODULE__{} = map), do: static_data(map)

  defp validate_required_expression(attrs, field, scope) do
    if Map.has_key?(attrs, field) do
      ElementValidation.expression(
        Map.fetch!(attrs, field),
        scope,
        "map collection",
        [field]
      )
    else
      {:error, Error.validation_error("map #{field} is required", %{path: [field]})}
    end
  end

  defp validate_input(nil), do: {:ok, %{}}

  defp validate_input(input),
    do: ElementValidation.expression(input, :map_input, "map target input", [:input])

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
