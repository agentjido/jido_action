defmodule Jido.Flow.Iterator do
  @moduledoc """
  A bounded, stateful Flow element.

  The public Spark DSL declares this canonical node with `iterate`. Its body
  iterations and State transitions are internal to one public Flow node.
  """

  alias Jido.Action
  alias Jido.Action.Error
  alias Jido.Flow.Condition
  alias Jido.Flow.Node
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
    with :ok <- validate_known_keys(attrs),
         {:ok, name} <- validate_name(Map.get(attrs, :name)),
         {:ok, action} <- validate_target(Map.get(attrs, :action)),
         {:ok, input} <- validate_input(Map.get(attrs, :input, %{})),
         {:ok, state} <- validate_state(Map.get(attrs, :state)),
         {:ok, completion} <- validate_completion(Map.get(attrs, :completion)),
         {:ok, max_iterations} <- validate_max_iterations(Map.get(attrs, :max_iterations)),
         {:ok, deps} <- validate_deps(Map.get(attrs, :deps, [])),
         {:ok, provenance} <- validate_provenance(Map.get(attrs, :provenance, %{})) do
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
    |> Node.collect_result_refs()
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
      input: Node.expression_to_map(iterator.input),
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
  @spec semantic_data(t()) :: map()
  def semantic_data(%__MODULE__{} = iterator) do
    %{
      kind: :iterate,
      name: iterator.name,
      action: iterator.action,
      input: iterator.input,
      state: State.semantic_data(iterator.state),
      completion: iterator.completion,
      max_iterations: iterator.max_iterations,
      deps: iterator.deps
    }
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
     Error.validation_error("iterator name must be a non-empty string or atom", %{path: [:name]})}
  end

  defp validate_target(action) when is_atom(action) and not is_nil(action), do: {:ok, action}

  defp validate_target(_action) do
    {:error,
     Error.validation_error("iterator body target must be a module atom", %{path: [:action]})}
  end

  defp validate_input(nil), do: {:ok, %{}}
  defp validate_input(input), do: validate_expression(input, :input, :iterate_input)

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
        {:error,
         error
         |> put_error_message(iterator_condition_message(Exception.message(error)))
         |> prefix_error_path(:completion)}
    end
  end

  defp iterator_condition_message(message) do
    String.replace(message, "choice condition", "iterator completion condition")
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
    owner = "iterator body input"

    case Node.expression_error_kind(error) do
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

  defp validate_deps(nil), do: {:ok, []}

  defp validate_deps(deps) when is_list(deps) do
    if List.improper?(deps) do
      invalid_deps("iterator deps must be a proper list")
    else
      deps
      |> Enum.reduce_while({:ok, []}, &collect_dependency/2)
      |> normalize_deps()
    end
  end

  defp validate_deps(_deps), do: invalid_deps("iterator deps must be a list")

  defp collect_dependency(dep, {:ok, acc}) do
    case validate_dependency(dep) do
      {:ok, dep} -> {:cont, {:ok, [dep | acc]}}
      :error -> {:halt, invalid_deps("iterator deps must be a list of step names")}
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
    {:error, Error.validation_error("iterator provenance must be a map", %{path: [:provenance]})}
  end

  defp validate_known_keys(attrs) do
    case attrs |> Map.keys() |> Enum.find(&(&1 not in @config_keys)) do
      nil ->
        :ok

      key ->
        {:error,
         Error.validation_error("unknown iterator configuration key: #{inspect(key)}", %{
           key: key,
           path: [key]
         })}
    end
  end

  defp put_error_message(%{message: _message} = error, message), do: %{error | message: message}
  defp put_error_message(error, _message), do: error

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
