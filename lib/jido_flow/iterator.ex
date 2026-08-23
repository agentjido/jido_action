defmodule Jido.Flow.Iterator do
  @moduledoc """
  A bounded, stateful Flow element.

  The public Spark DSL declares this canonical node with `iterate`. Its body
  iterations and State transitions are internal to one public Flow node.
  """

  alias Jido.Action.Error
  alias Jido.Flow.Condition
  alias Jido.Flow.Element.Validation, as: ElementValidation
  alias Jido.Flow.Expression
  alias Jido.Flow.State
  alias Jido.Instruction

  @maximum_iterations 10_000
  @config_keys [
    :name,
    :action,
    :input,
    :state,
    :completion,
    :max_iterations,
    :deps,
    :provenance
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          action: module(),
          input: term(),
          state: State.t(),
          completion: Condition.t(),
          max_iterations: pos_integer(),
          deps: [String.t()],
          provenance: map()
        }

  @enforce_keys @config_keys
  defstruct @config_keys

  @doc "Builds a canonical bounded Iterator."
  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, Exception.t()}
  def new(%__MODULE__{} = iterator), do: iterator |> Map.from_struct() |> new()

  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs), do: attrs |> Map.new() |> new(), else: invalid_configuration()
  end

  def new(%{} = attrs) do
    with :ok <- ElementValidation.known_keys(attrs, @config_keys, "iterator"),
         {:ok, name} <- ElementValidation.name(Map.get(attrs, :name), :iterator),
         {:ok, action} <-
           ElementValidation.target(Map.get(attrs, :action), {:label, "iterator body"}, [
             :action
           ]),
         {:ok, input} <- validate_input(Map.get(attrs, :input, %{})),
         {:ok, state} <- validate_state(Map.get(attrs, :state)),
         {:ok, completion} <- validate_completion(Map.get(attrs, :completion)),
         {:ok, max_iterations} <- validate_max_iterations(Map.get(attrs, :max_iterations)),
         {:ok, deps} <- ElementValidation.deps(Map.get(attrs, :deps, []), :iterator),
         {:ok, provenance} <-
           ElementValidation.provenance(Map.get(attrs, :provenance, %{}), :iterator) do
      {:ok,
       %__MODULE__{
         name: name,
         action: action,
         input: input,
         state: state,
         completion: completion,
         max_iterations: max_iterations,
         deps: deps,
         provenance: provenance
       }}
    end
  end

  def new(_attrs), do: invalid_configuration()

  @doc "Builds an Iterator or raises on validation failure."
  @spec new!(map() | keyword() | t()) :: t() | no_return()
  def new!(attrs) do
    case new(attrs) do
      {:ok, iterator} -> iterator
      {:error, error} -> raise error
    end
  end

  @doc false
  @spec result_deps(t()) :: [String.t()]
  def result_deps(%__MODULE__{} = iterator) do
    iterator.input
    |> Expression.result_refs()
    |> Kernel.++(State.result_deps(iterator.state))
    |> Kernel.++(Condition.result_deps(iterator.completion))
    |> Kernel.++(iterator.deps)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc false
  @spec put_deps(t(), [String.t()]) :: t()
  def put_deps(%__MODULE__{} = iterator, deps), do: %{iterator | deps: deps}

  @doc false
  @spec check(t()) :: :ok | {:error, Exception.t()}
  def check(%__MODULE__{} = iterator) do
    case Instruction.validate_action_contract(iterator.action) do
      :ok ->
        :ok

      {:error, error} ->
        {:error,
         Error.validation_error(
           error.message,
           error.details |> Map.merge(%{iterator: iterator.name, target: iterator.action})
         )}
    end
  end

  @doc false
  @spec to_map(t(), keyword()) :: map()
  def to_map(%__MODULE__{} = iterator, opts \\ []) do
    base = %{
      kind: :iterate,
      name: iterator.name,
      action: iterator.action,
      input: Expression.to_map(iterator.input),
      state: State.to_map(iterator.state),
      completion: Condition.to_map(iterator.completion),
      max_iterations: iterator.max_iterations,
      deps: Enum.sort(iterator.deps)
    }

    if Keyword.get(opts, :provenance, false) do
      Map.put(base, :provenance, iterator.provenance)
    else
      base
    end
  end

  @doc false
  @spec static_data(t()) :: map()
  def static_data(%__MODULE__{} = iterator) do
    %{
      kind: :iterate,
      name: iterator.name,
      action: iterator.action,
      input: iterator.input,
      state: State.static_data(iterator.state),
      completion: iterator.completion,
      max_iterations: iterator.max_iterations,
      deps: iterator.deps
    }
  end

  @doc false
  @spec semantic_data(t()) :: map()
  def semantic_data(%__MODULE__{} = iterator), do: static_data(iterator)

  defp validate_input(nil), do: {:ok, %{}}

  defp validate_input(input),
    do: ElementValidation.expression(input, :iterate_input, "iterator body input", [:input])

  defp validate_state(nil) do
    {:error, Error.validation_error("iterator state is required", %{path: [:state]})}
  end

  defp validate_state(state) do
    case State.new(state) do
      {:ok, state} -> {:ok, state}
      {:error, error} -> {:error, prefix_error_path(error, :state)}
    end
  end

  defp validate_completion(nil) do
    {:error, Error.validation_error("iterator completion is required", %{path: [:completion]})}
  end

  defp validate_completion(completion) do
    case Condition.validate(completion, :iterate_completion) do
      {:ok, completion} ->
        {:ok, completion}

      {:error, error} ->
        {:error, prefix_error_path(error, :completion)}
    end
  end

  defp validate_max_iterations(value)
       when is_integer(value) and value >= 1 and value <= @maximum_iterations,
       do: {:ok, value}

  defp validate_max_iterations(_value) do
    {:error,
     Error.validation_error(
       "iterator max_iterations must be an integer from 1 to 10000",
       %{path: [:max_iterations]}
     )}
  end

  defp prefix_error_path(%{details: details} = error, prefix) when is_map(details) do
    current = Map.get(details, :path, [])
    path = if List.first(current) == prefix, do: current, else: [prefix | current]
    %{error | details: Map.put(details, :path, path)}
  end

  defp prefix_error_path(error, _prefix), do: error

  defp invalid_configuration do
    {:error, Error.validation_error("iterator configuration must be a map", %{path: []})}
  end
end
