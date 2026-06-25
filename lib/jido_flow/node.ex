defmodule Jido.Flow.Node do
  @moduledoc """
  A named action invocation inside a canonical Flow artifact.
  """

  alias Jido.Action.Error
  alias Jido.Flow.Ref

  @schema Zoi.struct(
            __MODULE__,
            %{
              name: Zoi.atom(description: "Flow step name"),
              action: Zoi.atom(description: "Action module"),
              input: Zoi.map(description: "Step input expression map") |> Zoi.default(%{}),
              deps: Zoi.list(Zoi.atom(), description: "Step dependencies") |> Zoi.default([]),
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
  def new(%__MODULE__{} = node), do: {:ok, normalize_deps(node)}
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(%{} = attrs) do
    with {:ok, name} <- validate_name(Map.get(attrs, :name)),
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
  @spec result_deps(t()) :: [atom()]
  def result_deps(%__MODULE__{} = node) do
    node.input
    |> collect_result_refs()
    |> Kernel.++(node.deps)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_deps(%__MODULE__{} = node) do
    %{node | deps: node |> result_deps()}
  end

  defp validate_name(name) when is_atom(name) and not is_nil(name), do: {:ok, name}

  defp validate_name(_name) do
    {:error, Error.validation_error("node name must be a non-nil atom")}
  end

  defp validate_action(action) when is_atom(action) and not is_nil(action), do: {:ok, action}

  defp validate_action(_action) do
    {:error, Error.validation_error("node action must be a module atom")}
  end

  defp validate_input(nil), do: {:ok, %{}}
  defp validate_input(input) when is_map(input), do: {:ok, input}

  defp validate_input(_input) do
    {:error, Error.validation_error("node input must be a map")}
  end

  defp validate_deps(nil), do: {:ok, []}

  defp validate_deps(deps) when is_list(deps) do
    if Enum.all?(deps, &(is_atom(&1) and not is_nil(&1))) do
      {:ok, deps |> Enum.uniq() |> Enum.sort()}
    else
      {:error, Error.validation_error("node deps must be a list of atoms")}
    end
  end

  defp validate_deps(_deps), do: {:error, Error.validation_error("node deps must be a list")}

  defp validate_provenance(nil), do: {:ok, %{}}
  defp validate_provenance(provenance) when is_map(provenance), do: {:ok, provenance}

  defp validate_provenance(_provenance) do
    {:error, Error.validation_error("node provenance must be a map")}
  end

  defp expression_to_map(%Ref{} = ref), do: Ref.to_map(ref)

  defp expression_to_map(%{} = map) do
    Map.new(map, fn {key, value} -> {key, expression_to_map(value)} end)
  end

  defp expression_to_map(list) when is_list(list), do: Enum.map(list, &expression_to_map/1)
  defp expression_to_map(value), do: Ref.value(value) |> Ref.to_map()

  defp collect_result_refs(%Ref{type: :result, node: node}), do: [node]
  defp collect_result_refs(%Ref{}), do: []

  defp collect_result_refs(%{} = map) do
    map
    |> Map.values()
    |> Enum.flat_map(&collect_result_refs/1)
  end

  defp collect_result_refs(list) when is_list(list),
    do: Enum.flat_map(list, &collect_result_refs/1)

  defp collect_result_refs(_value), do: []
end
