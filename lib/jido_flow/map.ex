defmodule Jido.Flow.Map do
  @moduledoc """
  A named Flow fan-out operation over one ordered collection.

  A Map is one public Flow element. Item work is internal to that element.
  """

  alias Jido.Action
  alias Jido.Action.Error
  alias Jido.Flow.Node
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

  @doc """
  Builds a Map from keyword or map attributes.
  """
  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, Exception.t()}
  def new(%__MODULE__{} = map), do: map |> Map.from_struct() |> new()

  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs), do: attrs |> Map.new() |> new(), else: invalid_configuration()
  end

  def new(%{} = attrs) do
    with :ok <- validate_known_keys(attrs),
         {:ok, name} <- validate_name(Map.get(attrs, :name)),
         {:ok, collection} <- validate_required_expression(attrs, :collection, :map_collection),
         {:ok, action} <- validate_target(Map.get(attrs, :action)),
         {:ok, input} <- validate_input(Map.get(attrs, :input, %{})),
         {:ok, on_error} <- validate_on_error(Map.get(attrs, :on_error, :fail_fast)),
         {:ok, deps} <- validate_deps(Map.get(attrs, :deps, [])),
         {:ok, provenance} <- validate_provenance(Map.get(attrs, :provenance, %{})) do
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

  @doc """
  Builds a Map or raises on validation failure.
  """
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
    |> Node.collect_result_refs()
    |> Kernel.++(Node.collect_result_refs(map.input))
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
      collection: Node.expression_to_map(map.collection),
      action: map.action,
      input: Node.expression_to_map(map.input),
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
  @spec semantic_data(t()) :: map()
  def semantic_data(%__MODULE__{} = map) do
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

  defp validate_required_expression(attrs, field, scope) do
    if Map.has_key?(attrs, field) do
      validate_expression(Map.fetch!(attrs, field), field, scope)
    else
      {:error, Error.validation_error("map #{field} is required", %{path: [field]})}
    end
  end

  defp validate_input(nil), do: {:ok, %{}}
  defp validate_input(input), do: validate_expression(input, :input, :map_input)

  defp validate_expression(expression, field, scope) do
    with {:ok, expression} <- Node.normalize_expression(expression),
         :ok <- Node.validate_expression(expression, scope) do
      {:ok, expression}
    else
      {:error, error} -> {:error, translate_expression_error(error, field)}
    end
  end

  defp translate_expression_error(error, field) do
    details = Map.get(error, :details, %{})
    path = [field] ++ Map.get(details, :path, [])
    owner = if field == :input, do: "map target input", else: "map collection"

    case Node.expression_error_kind(error) do
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
     Error.validation_error("map name must be a non-empty string or atom", %{path: [:name]})}
  end

  defp validate_target(action) when is_atom(action) and not is_nil(action), do: {:ok, action}

  defp validate_target(_action) do
    {:error, Error.validation_error("map target must be a module atom", %{path: [:action]})}
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

  defp validate_deps(nil), do: {:ok, []}

  defp validate_deps(deps) when is_list(deps) do
    if List.improper?(deps) do
      invalid_deps("map deps must be a proper list")
    else
      validate_proper_deps(deps)
    end
  end

  defp validate_deps(_deps), do: invalid_deps("map deps must be a list")

  defp validate_proper_deps(deps) do
    deps
    |> Enum.reduce_while({:ok, []}, &collect_dependency/2)
    |> normalize_deps()
  end

  defp collect_dependency(dep, {:ok, acc}) do
    case validate_dependency(dep) do
      {:ok, dep} -> {:cont, {:ok, [dep | acc]}}
      :error -> {:halt, invalid_deps("map deps must be a list of step names")}
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
    {:error, Error.validation_error("map provenance must be a map", %{path: [:provenance]})}
  end

  defp validate_known_keys(attrs) do
    case attrs |> Map.keys() |> Enum.find(&(&1 not in @config_keys)) do
      nil ->
        :ok

      key ->
        {:error,
         Error.validation_error("unknown map configuration key: #{inspect(key)}", %{
           key: key,
           path: [key]
         })}
    end
  end

  defp invalid_configuration,
    do: {:error, Error.validation_error("map configuration must be a map", %{path: []})}
end
