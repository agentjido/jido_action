defmodule Jido.Flow.Node do
  @moduledoc """
  A named action invocation inside a canonical Flow artifact.
  """

  alias Jido.Action
  alias Jido.Action.Error
  alias Jido.Flow.Ref

  @config_keys [:name, :action, :input, :deps, :provenance]

  @schema Zoi.struct(
            __MODULE__,
            %{
              name: Zoi.string(description: "Flow step name"),
              action: Zoi.atom(description: "Action module"),
              input: Zoi.any(description: "Step input expression") |> Zoi.default(%{}),
              deps: Zoi.list(Zoi.string(), description: "Step dependencies") |> Zoi.default([]),
              provenance: Zoi.map(description: "Non-semantic provenance") |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc """
  Builds a Flow node from keyword or map attributes.
  """
  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, Exception.t()}
  def new(%__MODULE__{} = node), do: node |> Map.from_struct() |> new()

  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs),
      do: attrs |> Map.new() |> new(),
      else: {:error, Error.validation_error("node configuration must be a map")}
  end

  def new(%{} = attrs) do
    with :ok <- validate_known_keys(attrs),
         {:ok, name} <- validate_name(Map.get(attrs, :name)),
         {:ok, action} <- validate_action(Map.get(attrs, :action)),
         {:ok, input} <- validate_input(Map.get(attrs, :input, %{})),
         {:ok, deps} <- validate_deps(Map.get(attrs, :deps, [])),
         {:ok, provenance} <- validate_provenance(Map.get(attrs, :provenance, %{})) do
      {:ok,
       %__MODULE__{
         name: name,
         action: action,
         input: input,
         deps: deps,
         provenance: provenance
       }}
    end
  end

  def new(_attrs), do: {:error, Error.validation_error("node configuration must be a map")}

  @doc """
  Builds a Flow node or raises on validation failure.
  """
  @spec new!(map() | keyword() | t()) :: t() | no_return()
  def new!(attrs) do
    case new(attrs) do
      {:ok, node} -> node
      {:error, error} when is_exception(error) -> raise error
    end
  end

  @doc false
  @spec to_map(t(), keyword()) :: map()
  def to_map(%__MODULE__{} = node, opts \\ []) do
    base = %{
      name: node.name,
      action: node.action,
      input: expression_to_map(node.input),
      deps: Enum.sort(node.deps)
    }

    if Keyword.get(opts, :provenance, false) do
      Map.put(base, :provenance, node.provenance)
    else
      base
    end
  end

  @doc false
  @spec result_deps(t()) :: [String.t()]
  def result_deps(%__MODULE__{} = node) do
    node.input
    |> collect_result_refs()
    |> Kernel.++(node.deps)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc false
  @spec normalize_expression(term()) :: {:ok, term()} | {:error, Exception.t()}
  def normalize_expression(expression), do: do_normalize_expression(expression, [])

  @doc false
  @spec validate_expression(term(), Ref.scope()) :: :ok | {:error, Exception.t()}
  def validate_expression(expression, scope \\ :flow),
    do: validate_input_expression(expression, [], scope)

  @doc false
  @spec expression_to_map(term()) :: term()
  def expression_to_map(%Ref{} = ref), do: Ref.to_map(ref)

  def expression_to_map(%{} = map) do
    Map.new(map, fn {key, value} -> {key, expression_to_map(value)} end)
  end

  def expression_to_map(list) when is_list(list), do: Enum.map(list, &expression_to_map/1)
  def expression_to_map(value), do: Ref.value(value) |> Ref.to_map()

  @doc false
  @spec collect_result_refs(term()) :: [String.t()]
  def collect_result_refs(%Ref{type: :result, node: node}), do: [node]
  def collect_result_refs(%Ref{}), do: []

  def collect_result_refs(%{} = map) do
    map
    |> Map.values()
    |> Enum.flat_map(&collect_result_refs/1)
  end

  def collect_result_refs(list) when is_list(list),
    do: Enum.flat_map(list, &collect_result_refs/1)

  def collect_result_refs(_value), do: []

  @doc false
  @spec expression_error_kind(Exception.t()) ::
          :invalid_ref_path
          | :invalid_ref
          | :invalid_scope
          | :improper_list
          | :unsupported_expression
          | :other
  def expression_error_kind(%{details: %{ref_type: _type, scope: _scope}}),
    do: :invalid_scope

  def expression_error_kind(%{details: %{segment: _segment}}), do: :invalid_ref_path
  def expression_error_kind(%{details: %{type: _type}}), do: :invalid_ref
  def expression_error_kind(%{details: %{reason: :improper_list}}), do: :improper_list
  def expression_error_kind(%{details: %{expression: _expression}}), do: :unsupported_expression
  def expression_error_kind(_error), do: :other

  defp validate_name(name) when is_atom(name) and not is_nil(name) do
    name
    |> Atom.to_string()
    |> validate_name()
  end

  defp validate_name(name) when is_binary(name) do
    case Action.validate_name(name) do
      :ok -> {:ok, name}
      {:error, message} -> {:error, Error.validation_error(message)}
    end
  end

  defp validate_name(_name) do
    {:error, Error.validation_error("node name must be a non-empty string or atom")}
  end

  defp validate_action(action) when is_atom(action) and not is_nil(action), do: {:ok, action}

  defp validate_action(_action) do
    {:error, Error.validation_error("node action must be a module atom")}
  end

  defp validate_input(nil), do: {:ok, %{}}

  defp validate_input(input) do
    with {:ok, input} <- normalize_expression(input),
         :ok <- validate_input_expression(input, [], :flow) do
      {:ok, input}
    end
  end

  defp validate_deps(nil), do: {:ok, []}

  defp validate_deps(deps) when is_list(deps) do
    if List.improper?(deps) do
      {:error, Error.validation_error("node deps must be a proper list")}
    else
      validate_proper_deps(deps)
    end
  end

  defp validate_deps(_deps), do: {:error, Error.validation_error("node deps must be a list")}

  defp validate_proper_deps(deps) do
    deps
    |> Enum.reduce_while({:ok, []}, fn dep, {:ok, acc} ->
      case validate_name(dep) do
        {:ok, dep} ->
          {:cont, {:ok, [dep | acc]}}

        {:error, _error} ->
          {:halt, {:error, Error.validation_error("node deps must be a list of step names")}}
      end
    end)
    |> case do
      {:ok, deps} -> {:ok, deps |> Enum.uniq() |> Enum.sort()}
      {:error, error} -> {:error, error}
    end
  end

  defp validate_provenance(nil), do: {:ok, %{}}
  defp validate_provenance(provenance) when is_map(provenance), do: {:ok, provenance}

  defp validate_provenance(_provenance) do
    {:error, Error.validation_error("node provenance must be a map")}
  end

  defp validate_input_expression(%Ref{} = ref, path, scope) do
    case Ref.validate(ref, scope) do
      :ok ->
        :ok

      {:error, %{details: %{reason: :path, segment: segment}}} ->
        {:error,
         Error.validation_error("node input contains invalid ref path", %{
           path: path,
           segment: segment
         })}

      {:error, %{details: %{reason: :scope, type: type, scope: invalid_scope}}} ->
        {:error,
         Error.validation_error(
           "flow expression contains a scoped ref outside its valid scope",
           %{path: path, ref_type: type, scope: invalid_scope}
         )}

      {:error, _error} ->
        invalid_ref_error(ref.type, path)
    end
  end

  defp validate_input_expression(%{} = map, path, scope) when not is_struct(map) do
    Enum.reduce_while(map, :ok, fn {key, value}, :ok ->
      case validate_input_expression(value, path ++ [key], scope) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp validate_input_expression(list, path, scope) when is_list(list) do
    if List.improper?(list) do
      improper_list_error(path)
    else
      validate_proper_list_expression(list, path, scope)
    end
  end

  defp validate_input_expression(%{__struct__: module}, path, _scope) do
    {:error,
     Error.validation_error("node input contains unsupported expression", %{
       path: path,
       expression: module
     })}
  end

  defp validate_input_expression(_value, _path, _scope), do: :ok

  defp do_normalize_expression(%Ref{type: :result, node: node} = ref, _path)
       when (is_atom(node) and not is_nil(node)) or is_binary(node) do
    case validate_name(node) do
      {:ok, node} -> {:ok, %{ref | node: node}}
      {:error, error} -> {:error, error}
    end
  end

  defp do_normalize_expression(%Ref{type: :result} = ref, _path), do: {:ok, ref}

  defp do_normalize_expression(%Ref{} = ref, _path), do: {:ok, ref}

  defp do_normalize_expression(%{} = map, path) when not is_struct(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case do_normalize_expression(value, path ++ [key]) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp do_normalize_expression(list, path) when is_list(list) do
    if List.improper?(list) do
      improper_list_error(path)
    else
      normalize_proper_list_expression(list, path)
    end
  end

  defp do_normalize_expression(value, _path), do: {:ok, value}

  defp validate_proper_list_expression(list, path, scope) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {value, index}, :ok ->
      case validate_input_expression(value, path ++ [index], scope) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp normalize_proper_list_expression(list, path) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, acc} ->
      case do_normalize_expression(value, path ++ [index]) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, error} -> {:error, error}
    end
  end

  defp validate_known_keys(attrs) do
    case attrs |> Map.keys() |> Enum.find(&(&1 not in @config_keys)) do
      nil ->
        :ok

      key ->
        {:error,
         Error.validation_error("unknown node configuration key: #{inspect(key)}", %{key: key})}
    end
  end

  defp invalid_ref_error(type, path) do
    {:error,
     Error.validation_error("node input contains invalid ref", %{
       path: path,
       type: type
     })}
  end

  defp improper_list_error(path) do
    {:error,
     Error.validation_error("flow expression must be a proper list", %{
       path: path,
       reason: :improper_list
     })}
  end
end
