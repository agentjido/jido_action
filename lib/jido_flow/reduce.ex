defmodule Jido.Flow.Reduce do
  @moduledoc """
  A named Flow fan-in operation over one ordered collection.

  A Reduce is one public Flow element. Its target calls form one serial left
  fold inside that element.
  """

  alias Jido.Action
  alias Jido.Action.Error
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
    with :ok <- validate_known_keys(attrs),
         {:ok, name} <- validate_name(Map.get(attrs, :name)),
         {:ok, collection} <-
           validate_required_expression(attrs, :collection, :reduce_collection),
         {:ok, initial} <- validate_required_expression(attrs, :initial, :reduce_initial),
         {:ok, action} <- validate_target(Map.get(attrs, :action)),
         {:ok, input} <- validate_input(Map.get(attrs, :input, %{})),
         {:ok, deps} <- validate_deps(Map.get(attrs, :deps, [])),
         {:ok, provenance} <- validate_provenance(Map.get(attrs, :provenance, %{})) do
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
  @spec semantic_data(t()) :: map()
  def semantic_data(%__MODULE__{} = reduce) do
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

  defp validate_required_expression(attrs, field, scope) do
    if Map.has_key?(attrs, field) do
      validate_expression(Map.fetch!(attrs, field), field, scope)
    else
      {:error, Error.validation_error("reduce #{field} is required", %{path: [field]})}
    end
  end

  defp validate_input(nil), do: {:ok, %{}}
  defp validate_input(input), do: validate_expression(input, :input, :reduce_input)

  defp validate_expression(expression, field, scope) do
    with {:ok, expression} <- Expression.normalize(expression),
         :ok <- Expression.validate(expression, scope) do
      {:ok, expression}
    else
      {:error, error} -> {:error, translate_expression_error(error, field)}
    end
  end

  defp translate_expression_error(error, field) do
    details = Map.get(error, :details, %{})
    path = [field] ++ Map.get(details, :path, [])
    owner = if field == :input, do: "reduce target input", else: "reduce #{field}"

    case Expression.error_kind(error) do
      :invalid_scope ->
        Error.validation_error(
          "flow expression contains a scoped ref outside its valid scope",
          %{path: path, ref_type: details.ref_type, scope: details.scope}
        )

      :invalid_ref_path ->
        Error.validation_error("#{owner} contains invalid ref path", %{
          path: path,
          segment: details.segment
        })

      :invalid_ref ->
        Error.validation_error("#{owner} contains invalid ref", %{
          path: path,
          type: details.type
        })

      :improper_list ->
        Error.validation_error("#{owner} must be a proper list", %{path: path})

      :unsupported_expression ->
        Error.validation_error("#{owner} contains unsupported expression", %{
          path: path,
          expression: details.expression
        })

      :other ->
        Error.validation_error("#{owner} must be static module data", %{path: [field]})
    end
  end

  defp validate_name(name) when is_atom(name) and not is_nil(name),
    do: name |> Atom.to_string() |> validate_name()

  defp validate_name(name) when is_binary(name) do
    case Action.validate_name(name) do
      :ok -> {:ok, name}
      {:error, _message} -> invalid_name()
    end
  end

  defp validate_name(_name), do: invalid_name()

  defp invalid_name do
    {:error,
     Error.validation_error("reduce name must be a non-empty string or atom", %{path: [:name]})}
  end

  defp validate_target(action) when is_atom(action) and not is_nil(action), do: {:ok, action}

  defp validate_target(_action) do
    {:error, Error.validation_error("reduce target must be a module atom", %{path: [:action]})}
  end

  defp validate_deps(nil), do: {:ok, []}

  defp validate_deps(deps) when is_list(deps) do
    if List.improper?(deps) do
      invalid_deps("reduce deps must be a proper list")
    else
      validate_proper_deps(deps)
    end
  end

  defp validate_deps(_deps), do: invalid_deps("reduce deps must be a list")

  defp validate_proper_deps(deps) do
    deps
    |> Enum.reduce_while({:ok, []}, &collect_dependency/2)
    |> normalize_deps()
  end

  defp collect_dependency(dep, {:ok, acc}) do
    case validate_dependency(dep) do
      {:ok, dep} -> {:cont, {:ok, [dep | acc]}}
      :error -> {:halt, invalid_deps("reduce deps must be a list of step names")}
    end
  end

  defp normalize_deps({:ok, deps}), do: {:ok, deps |> Enum.uniq() |> Enum.sort()}
  defp normalize_deps({:error, error}), do: {:error, error}

  defp validate_dependency(dep) when is_atom(dep) and not is_nil(dep),
    do: dep |> Atom.to_string() |> validate_dependency()

  defp validate_dependency(dep) when is_binary(dep) do
    case Action.validate_name(dep) do
      :ok -> {:ok, dep}
      {:error, _message} -> :error
    end
  end

  defp validate_dependency(_dep), do: :error

  defp invalid_deps(message),
    do: {:error, Error.validation_error(message, %{path: [:deps]})}

  defp validate_provenance(nil), do: {:ok, %{}}
  defp validate_provenance(provenance) when is_map(provenance), do: {:ok, provenance}

  defp validate_provenance(_provenance) do
    {:error, Error.validation_error("reduce provenance must be a map", %{path: [:provenance]})}
  end

  defp validate_known_keys(attrs) do
    case attrs |> Map.keys() |> Enum.find(&(&1 not in @config_keys)) do
      nil ->
        :ok

      key ->
        {:error,
         Error.validation_error("unknown reduce configuration key: #{inspect(key)}", %{
           key: key,
           path: [key]
         })}
    end
  end

  defp invalid_configuration,
    do: {:error, Error.validation_error("reduce configuration must be a map", %{path: []})}
end
