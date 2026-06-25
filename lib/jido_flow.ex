defmodule Jido.Flow do
  @moduledoc """
  Canonical v4 Flow artifact.

  A Flow is a data artifact describing named action calls and a declared return
  reference. Authoring surfaces lower into this struct; execution is delegated
  through `Jido.Exec`.
  """

  alias Jido.Action
  alias Jido.Action.Error
  alias Jido.Flow.{Node, Ref}
  alias Jido.Instruction

  @schema Zoi.struct(
            __MODULE__,
            %{
              name: Zoi.string(description: "Flow name"),
              description: Zoi.string(description: "Flow description") |> Zoi.optional(),
              schema: Zoi.any(description: "Flow input schema") |> Zoi.default([]),
              output_schema: Zoi.any(description: "Flow output schema") |> Zoi.default([]),
              nodes: Zoi.list(Zoi.any(), description: "Canonical Flow nodes") |> Zoi.default([]),
              return: Zoi.any(description: "Declared return reference"),
              provenance: Zoi.map(description: "Non-semantic provenance") |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc """
  Builds and validates a canonical Flow artifact.
  """
  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, Exception.t()}
  def new(%__MODULE__{} = flow), do: validate(flow)
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(%{} = attrs) do
    with {:ok, name} <- validate_name(Map.get(attrs, :name)),
         {:ok, description} <- validate_description(Map.get(attrs, :description)),
         {:ok, schema} <- validate_schema(Map.get(attrs, :schema, []), "schema"),
         {:ok, output_schema} <-
           validate_schema(Map.get(attrs, :output_schema, []), "output_schema"),
         {:ok, nodes} <- normalize_nodes(Map.get(attrs, :nodes, [])),
         {:ok, return} <- validate_return(Map.get(attrs, :return)),
         {:ok, provenance} <- validate_provenance(Map.get(attrs, :provenance, %{})) do
      %__MODULE__{
        name: name,
        description: description,
        schema: schema,
        output_schema: output_schema,
        nodes: nodes,
        return: return,
        provenance: provenance
      }
      |> validate()
    end
  end

  def new(_attrs), do: {:error, Error.validation_error("flow configuration must be a map")}

  @doc """
  Builds a Flow artifact or raises on validation failure.
  """
  @spec new!(map() | keyword() | t()) :: t() | no_return()
  def new!(attrs) do
    case new(attrs) do
      {:ok, flow} -> flow
      {:error, error} when is_exception(error) -> raise error
    end
  end

  @doc """
  Converts a Flow artifact to its deterministic semantic map.

  Provenance is omitted by default because it does not participate in semantic
  equality.
  """
  @spec to_map(t(), keyword()) :: map()
  def to_map(%__MODULE__{} = flow, opts \\ []) do
    base = %{
      type: :flow,
      name: flow.name,
      description: flow.description,
      schema: flow.schema,
      output_schema: flow.output_schema,
      nodes: Enum.map(flow.nodes, &Node.to_map(&1, opts)),
      return: Ref.to_map(flow.return)
    }

    if Keyword.get(opts, :provenance, false) do
      Map.put(base, :provenance, flow.provenance)
    else
      base
    end
  end

  @doc false
  @spec validate(t()) :: {:ok, t()} | {:error, Exception.t()}
  def validate(%__MODULE__{} = flow) do
    with :ok <- validate_duplicate_nodes(flow.nodes),
         :ok <- validate_action_contracts(flow.nodes),
         :ok <- validate_known_result_refs(flow) do
      {:ok, normalize_node_deps(flow)}
    end
  end

  defp validate_name(name) when is_binary(name) do
    case Action.validate_name(name) do
      :ok -> {:ok, name}
      {:error, message} -> {:error, Error.validation_error(message)}
    end
  end

  defp validate_name(_name), do: {:error, Error.validation_error("flow name must be a string")}

  defp validate_description(nil), do: {:ok, nil}
  defp validate_description(description) when is_binary(description), do: {:ok, description}

  defp validate_description(_description) do
    {:error, Error.validation_error("flow description must be a string")}
  end

  defp validate_schema(nil, _field), do: {:ok, []}

  defp validate_schema(schema, field) do
    case Action.validate_config_schema(schema) do
      :ok ->
        {:ok, schema}

      {:error, message} ->
        {:error, Error.validation_error("#{field} #{message}", %{field: field})}
    end
  end

  defp normalize_nodes(nodes) when is_list(nodes) do
    nodes
    |> Enum.reduce_while({:ok, []}, fn attrs, {:ok, acc} ->
      case Node.new(attrs) do
        {:ok, node} -> {:cont, {:ok, [node | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, nodes} -> {:ok, Enum.reverse(nodes)}
      {:error, error} -> {:error, error}
    end
  end

  defp normalize_nodes(_nodes), do: {:error, Error.validation_error("flow nodes must be a list")}

  defp validate_return(%Ref{type: :result} = ref), do: {:ok, ref}

  defp validate_return(nil) do
    {:error, Error.validation_error("return ref is required")}
  end

  defp validate_return(_return) do
    {:error, Error.validation_error("return must be a result ref")}
  end

  defp validate_provenance(nil), do: {:ok, %{}}
  defp validate_provenance(provenance) when is_map(provenance), do: {:ok, provenance}

  defp validate_provenance(_provenance) do
    {:error, Error.validation_error("flow provenance must be a map")}
  end

  defp validate_duplicate_nodes(nodes) do
    nodes
    |> Enum.map(& &1.name)
    |> Enum.find(fn name -> Enum.count(nodes, &(&1.name == name)) > 1 end)
    |> case do
      nil ->
        :ok

      name ->
        {:error, Error.validation_error("duplicate step name: #{inspect(name)}", %{name: name})}
    end
  end

  defp validate_action_contracts(nodes) do
    Enum.reduce_while(nodes, :ok, fn node, :ok ->
      case Instruction.validate_action_contract(node.action) do
        :ok ->
          {:cont, :ok}

        {:error, error} ->
          details =
            error.details
            |> Map.put(:node, node.name)
            |> Map.put(:action, node.action)

          {:halt, {:error, Error.validation_error(error.message, details)}}
      end
    end)
  end

  defp validate_known_result_refs(%__MODULE__{} = flow) do
    known = flow.nodes |> Enum.map(& &1.name) |> MapSet.new()

    cond do
      not MapSet.member?(known, flow.return.node) ->
        {:error,
         Error.validation_error(
           "return ref points to an unknown step: #{inspect(flow.return.node)}",
           %{
             node: flow.return.node,
             ref: Ref.to_map(flow.return)
           }
         )}

      true ->
        validate_node_result_refs(flow.nodes, known)
    end
  end

  defp validate_node_result_refs(nodes, known) do
    Enum.reduce_while(nodes, :ok, fn node, :ok ->
      missing = node |> Node.result_deps() |> Enum.reject(&MapSet.member?(known, &1))

      case missing do
        [] ->
          {:cont, :ok}

        [missing_node | _] ->
          {:halt,
           {:error,
            Error.validation_error(
              "node input points to an unknown step: #{inspect(missing_node)}",
              %{
                node: node.name,
                dependency: missing_node
              }
            )}}
      end
    end)
  end

  defp normalize_node_deps(%__MODULE__{} = flow) do
    nodes =
      Enum.map(flow.nodes, fn node ->
        %{node | deps: Node.result_deps(node)}
      end)

    %{flow | nodes: nodes}
  end
end
