defmodule Jido.Flow.MapCodec.Decoder do
  @moduledoc false

  alias Jido.Flow.MapCodec.ChoiceDecoder
  alias Jido.Flow.MapCodec.CollectionDecoder
  alias Jido.Flow.MapCodec.DataDecoder
  alias Jido.Flow.MapCodec.ErrorPath
  alias Jido.Flow.MapCodec.ExpressionDecoder
  alias Jido.Flow.MapCodec.IteratorDecoder
  alias Jido.Flow.MapCodec.RecordValidator
  alias Jido.Flow.MapCodec.RegistryLookup
  alias Jido.Flow.Registry
  alias Jido.Flow.ResourceBudget

  @doc false
  def decode(%{} = map, %Registry{} = registry) do
    with :ok <- ResourceBudget.validate(map),
         :ok <- RecordValidator.validate_root_header(map),
         :ok <- RecordValidator.validate_root(map),
         {:ok, decoded} <- decode_flow(map, registry) do
      RegistryLookup.resolve(decoded, registry)
    end
  end

  defp decode_flow(map, registry) do
    with {:ok, name} <- RecordValidator.fetch_required(map, :name, "flow map name is required"),
         {:ok, input_schema} <- decode_root_schema(map, :input_schema),
         {:ok, output_schema} <- decode_root_schema(map, :output_schema),
         {:ok, nodes} <-
           RecordValidator.fetch_required(map, :nodes, "flow map nodes are required"),
         {:ok, return} <-
           RecordValidator.fetch_required(map, :return, "flow map return is required"),
         {:ok, nodes} <- decode_nodes(nodes, registry),
         {:ok, return} <-
           ExpressionDecoder.decode(return, registry)
           |> ErrorPath.prepend([RecordValidator.field(:return)]),
         {:ok, provenance} <-
           DataDecoder.decode_optional(map, :provenance, %{}, registry)
           |> ErrorPath.prepend([RecordValidator.field(:provenance)]) do
      {:ok,
       %{
         name: name,
         description: RecordValidator.fetch_optional(map, :description, nil),
         schema: input_schema,
         output_schema: output_schema,
         nodes: nodes,
         return: return,
         provenance: provenance
       }}
    end
  end

  defp decode_root_schema(map, field) do
    RecordValidator.fetch_required(map, field, "flow #{field} is required")
    |> then(fn
      {:ok, identifier} -> RegistryLookup.decode_identifier(identifier, :schema)
      {:error, error} -> {:error, error}
    end)
    |> ErrorPath.prepend([RecordValidator.field(field)])
  end

  defp decode_nodes(nodes, registry) when is_list(nodes) do
    if List.improper?(nodes) do
      ErrorPath.error("flow nodes must be a list")
    else
      nodes
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {node, index}, {:ok, acc} ->
        case decode_node(node, registry)
             |> ErrorPath.prepend([RecordValidator.field(:nodes), index]) do
          {:ok, node} -> {:cont, {:ok, [node | acc]}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
      |> case do
        {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
        {:error, error} -> {:error, error}
      end
    end
  end

  defp decode_nodes(_nodes, _registry), do: ErrorPath.error("flow nodes must be a list")

  defp decode_node(%{} = node, registry) do
    case explicit_node_kind(node) do
      {:ok, :choice} ->
        ChoiceDecoder.decode(node, registry)

      {:ok, :map} ->
        CollectionDecoder.decode_map(node, registry)

      {:ok, :reduce} ->
        CollectionDecoder.decode_reduce(node, registry)

      {:ok, :iterate} ->
        IteratorDecoder.decode(node, registry)

      {:error, kind} ->
        ErrorPath.error("unknown flow node kind: #{inspect(kind)}", %{kind: kind})

      :none ->
        if legacy_choice_record?(node),
          do: ChoiceDecoder.decode(node, registry),
          else: decode_step(node, registry)
    end
  end

  defp decode_node(_node, _registry), do: ErrorPath.error("flow node must be a map")

  defp decode_step(node, registry) do
    with :ok <- RecordValidator.validate_node_record(node),
         {:ok, name} <-
           RecordValidator.fetch_required(node, :name, "flow node name is required"),
         {:ok, action} <-
           RecordValidator.fetch_required(node, :action, "flow node action is required"),
         {:ok, action} <-
           RegistryLookup.decode_identifier(action, :action)
           |> ErrorPath.prepend([RecordValidator.field(:action)]),
         {:ok, input} <-
           ExpressionDecoder.decode(RecordValidator.fetch_optional(node, :input, %{}), registry)
           |> ErrorPath.prepend([RecordValidator.field(:input)]),
         {:ok, provenance} <-
           DataDecoder.decode_optional(node, :provenance, %{}, registry)
           |> ErrorPath.prepend([RecordValidator.field(:provenance)]),
         {:ok, deps} <-
           RecordValidator.validate_node_deps(RecordValidator.fetch_optional(node, :deps, [])) do
      {:ok,
       %{
         kind: :step,
         name: name,
         action: action,
         input: input,
         deps: deps,
         provenance: provenance
       }}
    end
  end

  defp explicit_node_kind(node) do
    case Map.fetch(node, "kind") do
      {:ok, "choice"} -> {:ok, :choice}
      {:ok, "map"} -> {:ok, :map}
      {:ok, "reduce"} -> {:ok, :reduce}
      {:ok, "iterate"} -> {:ok, :iterate}
      {:ok, kind} -> {:error, kind}
      :error -> :none
    end
  end

  defp legacy_choice_record?(node) do
    Map.has_key?(node, "options") or Map.has_key?(node, "fallback")
  end
end
