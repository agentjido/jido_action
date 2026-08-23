defmodule Jido.Flow.MapCodec.RegistryLookup do
  @moduledoc false

  alias Jido.Flow.Element
  alias Jido.Flow.Iterator
  alias Jido.Flow.MapCodec.ErrorPath
  alias Jido.Flow.Registry

  @doc false
  def writer_identifiers(flow, ordered_nodes, registry) do
    with {:ok, input_schema_id} <- Registry.identifier(registry, :schema, flow.schema),
         {:ok, output_schema_id} <- Registry.identifier(registry, :schema, flow.output_schema),
         {:ok, action_ids} <- writer_action_ids(registry, ordered_nodes),
         {:ok, iterator_schema_ids} <- writer_iterator_schema_ids(registry, ordered_nodes) do
      {:ok, {input_schema_id, output_schema_id, action_ids, iterator_schema_ids}}
    end
  end

  @doc false
  def decode_identifier(identifier, kind) do
    if Registry.valid_identifier?(identifier) do
      {:ok, identifier}
    else
      ErrorPath.error("invalid flow registry identifier", %{kind: kind, identifier: identifier})
    end
  end

  @doc false
  def resolve(decoded, registry) do
    with {:ok, input_schema} <-
           Registry.resolve(registry, decoded.schema, :schema)
           |> ErrorPath.prepend(["input_schema"]),
         {:ok, output_schema} <-
           Registry.resolve(registry, decoded.output_schema, :schema)
           |> ErrorPath.prepend(["output_schema"]),
         {:ok, nodes} <- resolve_node_actions(decoded.nodes, registry) do
      {:ok,
       decoded
       |> Map.put(:schema, input_schema)
       |> Map.put(:output_schema, output_schema)
       |> Map.put(:nodes, nodes)}
    end
  end

  defp writer_action_ids(registry, ordered_nodes) do
    ordered_nodes
    |> Enum.flat_map(&Element.target_modules/1)
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, %{}}, fn module, {:ok, acc} ->
      case Registry.identifier(registry, :action, module) do
        {:ok, identifier} -> {:cont, {:ok, Map.put(acc, module, identifier)}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp writer_iterator_schema_ids(registry, ordered_nodes) do
    ordered_nodes
    |> Enum.filter(&match?(%Iterator{}, &1))
    |> Enum.reduce_while({:ok, %{}}, fn iterator, {:ok, acc} ->
      case Registry.identifier(registry, :schema, iterator.state.schema) do
        {:ok, identifier} -> {:cont, {:ok, Map.put(acc, iterator.name, identifier)}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp resolve_node_actions(nodes, registry) do
    nodes
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {node, index}, {:ok, acc} ->
      case resolve_node_action(node, registry) |> ErrorPath.prepend(["nodes", index]) do
        {:ok, node} -> {:cont, {:ok, [node | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, nodes} -> {:ok, Enum.reverse(nodes)}
      {:error, error} -> {:error, error}
    end
  end

  defp resolve_node_action(%{options: options, fallback: fallback} = choice, registry) do
    with {:ok, options} <- resolve_choice_actions(options, registry),
         {:ok, fallback_action} <-
           Registry.resolve(registry, fallback.action, :action)
           |> ErrorPath.prepend(["fallback", "action"]) do
      {:ok,
       %{
         choice
         | options: options,
           fallback: %{fallback | action: fallback_action}
       }}
    end
  end

  defp resolve_node_action(%{kind: :iterate, action: identifier} = iterator, registry) do
    with {:ok, action} <-
           Registry.resolve(registry, identifier, :action) |> ErrorPath.prepend(["action"]),
         {:ok, schema} <-
           Registry.resolve(registry, iterator.state.schema, :schema)
           |> ErrorPath.prepend(["state", "schema"]) do
      {:ok, %{iterator | action: action, state: %{iterator.state | schema: schema}}}
    end
  end

  defp resolve_node_action(%{action: identifier} = node, registry) do
    case Registry.resolve(registry, identifier, :action) |> ErrorPath.prepend(["action"]) do
      {:ok, action} -> {:ok, %{node | action: action}}
      {:error, error} -> {:error, error}
    end
  end

  defp resolve_choice_actions(options, registry) do
    options
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {option, index}, {:ok, acc} ->
      case Registry.resolve(registry, option.action, :action)
           |> ErrorPath.prepend(["options", index, "action"]) do
        {:ok, action} -> {:cont, {:ok, [%{option | action: action} | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, options} -> {:ok, Enum.reverse(options)}
      {:error, error} -> {:error, error}
    end
  end
end
