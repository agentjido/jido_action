defmodule Jido.Flow.Reduce do
  @moduledoc """
  A named Flow fan-in operation over one ordered collection.

  A Reduce is one public Flow element. Its target calls form one serial left
  fold inside that element.
  """

  alias Jido.Action.Error
  alias Jido.Flow.Element.Validation, as: ElementValidation
  alias Jido.Flow.Expression
  alias Jido.Instruction

  @config_keys [:name, :collection, :initial, :action, :input, :deps, :provenance]

  @type t :: %__MODULE__{
          name: String.t(),
          collection: term(),
          initial: term(),
          action: module(),
          input: term(),
          deps: [String.t()],
          provenance: map()
        }

  @enforce_keys @config_keys
  defstruct @config_keys

  @doc """
  Builds a Reduce from keyword or map attributes.
  """
  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, Exception.t()}
  def new(%__MODULE__{} = reduce), do: reduce |> Map.from_struct() |> new()

  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs), do: attrs |> Map.new() |> new(), else: invalid_configuration()
  end

  def new(%{} = attrs) do
    with :ok <- ElementValidation.known_keys(attrs, @config_keys, "reduce"),
         {:ok, name} <- ElementValidation.name(Map.get(attrs, :name), :reduce),
         {:ok, collection} <-
           validate_required_expression(attrs, :collection, :reduce_collection),
         {:ok, initial} <- validate_required_expression(attrs, :initial, :reduce_initial),
         {:ok, action} <-
           ElementValidation.target(Map.get(attrs, :action), :reduce, [:action]),
         {:ok, input} <- validate_input(Map.get(attrs, :input, %{})),
         {:ok, deps} <- ElementValidation.deps(Map.get(attrs, :deps, []), :reduce),
         {:ok, provenance} <-
           ElementValidation.provenance(Map.get(attrs, :provenance, %{}), :reduce) do
      {:ok,
       %__MODULE__{
         name: name,
         collection: collection,
         initial: initial,
         action: action,
         input: input,
         deps: deps,
         provenance: provenance
       }}
    end
  end

  def new(_attrs), do: invalid_configuration()

  @doc """
  Builds a Reduce or raises on validation failure.
  """
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
    |> Kernel.++(Expression.result_refs(reduce.input))
    |> Kernel.++(reduce.deps)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc false
  @spec put_deps(t(), [String.t()]) :: t()
  def put_deps(%__MODULE__{} = reduce, deps), do: %{reduce | deps: deps}

  @doc false
  @spec check(t()) :: :ok | {:error, Exception.t()}
  def check(%__MODULE__{} = reduce) do
    case Instruction.validate_action_contract(reduce.action) do
      :ok ->
        :ok

      {:error, error} ->
        {:error,
         Error.validation_error(
           error.message,
           error.details |> Map.merge(%{reduce: reduce.name, target: reduce.action})
         )}
    end
  end

  @doc false
  @spec to_map(t(), keyword()) :: map()
  def to_map(%__MODULE__{} = reduce, opts \\ []) do
    base = %{
      kind: :reduce,
      name: reduce.name,
      collection: Expression.to_map(reduce.collection),
      initial: Expression.to_map(reduce.initial),
      action: reduce.action,
      input: Expression.to_map(reduce.input),
      deps: Enum.sort(reduce.deps)
    }

    if Keyword.get(opts, :provenance, false) do
      Map.put(base, :provenance, reduce.provenance)
    else
      base
    end
  end

  @doc false
  @spec static_data(t()) :: map()
  def static_data(%__MODULE__{} = reduce) do
    %{
      kind: :reduce,
      name: reduce.name,
      collection: reduce.collection,
      initial: reduce.initial,
      action: reduce.action,
      input: reduce.input,
      deps: reduce.deps
    }
  end

  @doc false
  @spec semantic_data(t()) :: map()
  def semantic_data(%__MODULE__{} = reduce), do: static_data(reduce)

  defp validate_required_expression(attrs, field, scope) do
    if Map.has_key?(attrs, field) do
      ElementValidation.expression(
        Map.fetch!(attrs, field),
        scope,
        "reduce #{field}",
        [field]
      )
    else
      {:error, Error.validation_error("reduce #{field} is required", %{path: [field]})}
    end
  end

  defp validate_input(nil), do: {:ok, %{}}

  defp validate_input(input),
    do: ElementValidation.expression(input, :reduce_input, "reduce target input", [:input])

  defp invalid_configuration,
    do: {:error, Error.validation_error("reduce configuration must be a map", %{path: []})}
end
