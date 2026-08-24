defmodule Jido.Flow.MapCodec.Encoder do
  @moduledoc false

  alias Jido.Action.Error

  alias Jido.Flow.{Choice, Iterator, Node, Reduce, Registry, ResourceBudget}
  alias Jido.Flow.Map, as: FlowMap

  alias Jido.Flow.MapCodec.DataEncoder
  alias Jido.Flow.MapCodec.ErrorPath
  alias Jido.Flow.MapCodec.ExpressionEncoder
  alias Jido.Flow.MapCodec.RecordValidator
  alias Jido.Flow.MapCodec.RegistryLookup

  @stored_version 1

  @doc false
  def to_stored_map!(flow, ordered_nodes, %Registry{} = registry, opts) do
    {input_schema_id, output_schema_id, action_ids, iterator_schema_ids} =
      validate_stored_writer!(flow, ordered_nodes, registry, opts)

    base = %{
      "type" => "flow",
      "version" => @stored_version,
      "name" => flow.name,
      "description" => flow.description,
      "input_schema" => input_schema_id,
      "output_schema" => output_schema_id,
      "nodes" =>
        ordered_nodes
        |> Enum.with_index()
        |> Enum.map(fn {element, index} ->
          stored_element!(
            element,
            action_ids,
            iterator_schema_ids,
            registry,
            opts,
            ["nodes", index]
          )
        end),
      "return" => ExpressionEncoder.encode!(flow.return, ["return"], registry)
    }

    stored =
      if Keyword.get(opts, :provenance, false) do
        Map.put(
          base,
          "provenance",
          DataEncoder.encode!(flow.provenance, ["provenance"], registry)
        )
      else
        base
      end

    case ResourceBudget.validate(stored) do
      :ok -> stored
      {:error, error} -> raise error
    end
  end

  @doc false
  def to_stored_map(flow, ordered_nodes, %Registry{} = registry, opts) do
    {:ok, to_stored_map!(flow, ordered_nodes, registry, opts)}
  rescue
    error in [Error.InvalidInputError] -> {:error, error}
  end

  defp validate_stored_writer!(flow, ordered_nodes, registry, opts) do
    case validate_stored_writer(flow, ordered_nodes, registry, opts) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  defp validate_stored_writer(flow, ordered_nodes, registry, opts) when is_list(opts) do
    with :ok <- validate_writer_options(opts) do
      RegistryLookup.writer_identifiers(flow, ordered_nodes, registry)
    end
  end

  defp validate_stored_writer(_flow, _ordered_nodes, _registry, _opts) do
    ErrorPath.error("flow map options must be a keyword list")
  end

  defp validate_writer_options(opts) do
    keys = Keyword.keys(opts)

    cond do
      not Keyword.keyword?(opts) ->
        ErrorPath.error("flow map options must be a keyword list")

      duplicate = RecordValidator.first_duplicate(keys) ->
        ErrorPath.error("duplicate flow map option: #{inspect(duplicate)}", %{option: duplicate})

      unknown = Enum.find(keys, &(&1 != :provenance)) ->
        ErrorPath.error("unknown flow map option: #{inspect(unknown)}", %{option: unknown})

      true ->
        :ok
    end
  end

  defp stored_element!(
         %Node{} = node,
         action_ids,
         _iterator_schema_ids,
         registry,
         opts,
         path
       ) do
    stored_node!(node, action_ids, registry, opts, path)
  end

  defp stored_element!(
         %Choice{} = choice,
         action_ids,
         _iterator_schema_ids,
         registry,
         opts,
         path
       ) do
    base = %{
      "kind" => "choice",
      "name" => choice.name,
      "options" =>
        choice.options
        |> Enum.with_index()
        |> Enum.map(fn {option, index} ->
          option_path = path ++ ["options", index]

          %{
            "name" => option.name,
            "condition" =>
              ExpressionEncoder.encode_condition!(
                option.condition,
                option_path ++ ["condition"],
                registry
              ),
            "action" => Map.fetch!(action_ids, option.action),
            "input" => ExpressionEncoder.encode!(option.input, option_path ++ ["input"], registry)
          }
        end),
      "fallback" => %{
        "name" => "fallback",
        "action" => Map.fetch!(action_ids, choice.fallback.action),
        "input" =>
          ExpressionEncoder.encode!(
            choice.fallback.input,
            path ++ ["fallback", "input"],
            registry
          )
      },
      "deps" => Enum.sort(choice.deps)
    }

    maybe_put_provenance(base, choice.provenance, registry, opts, path)
  end

  defp stored_element!(
         %FlowMap{} = map,
         action_ids,
         _iterator_schema_ids,
         registry,
         opts,
         path
       ) do
    base = %{
      "kind" => "map",
      "name" => map.name,
      "collection" => ExpressionEncoder.encode!(map.collection, path ++ ["collection"], registry),
      "action" => Map.fetch!(action_ids, map.action),
      "input" => ExpressionEncoder.encode!(map.input, path ++ ["input"], registry),
      "on_error" => Atom.to_string(map.on_error),
      "deps" => Enum.sort(map.deps)
    }

    maybe_put_provenance(base, map.provenance, registry, opts, path)
  end

  defp stored_element!(
         %Reduce{} = reduce,
         action_ids,
         _iterator_schema_ids,
         registry,
         opts,
         path
       ) do
    base = %{
      "kind" => "reduce",
      "name" => reduce.name,
      "collection" =>
        ExpressionEncoder.encode!(reduce.collection, path ++ ["collection"], registry),
      "initial" => ExpressionEncoder.encode!(reduce.initial, path ++ ["initial"], registry),
      "action" => Map.fetch!(action_ids, reduce.action),
      "input" => ExpressionEncoder.encode!(reduce.input, path ++ ["input"], registry),
      "deps" => Enum.sort(reduce.deps)
    }

    maybe_put_provenance(base, reduce.provenance, registry, opts, path)
  end

  defp stored_element!(
         %Iterator{} = iterator,
         action_ids,
         iterator_schema_ids,
         registry,
         opts,
         path
       ) do
    base = %{
      "kind" => "iterate",
      "name" => iterator.name,
      "action" => Map.fetch!(action_ids, iterator.action),
      "input" => ExpressionEncoder.encode!(iterator.input, path ++ ["input"], registry),
      "state" => %{
        "kind" => "iterate_state",
        "version" => iterator.state.version,
        "schema" => Map.fetch!(iterator_schema_ids, iterator.name),
        "initial" =>
          ExpressionEncoder.encode!(
            iterator.state.initial,
            path ++ ["state", "initial"],
            registry
          ),
        "update" =>
          ExpressionEncoder.encode!(
            iterator.state.update,
            path ++ ["state", "update"],
            registry
          )
      },
      "completion" =>
        ExpressionEncoder.encode_condition!(
          iterator.completion,
          path ++ ["completion"],
          registry
        ),
      "max_iterations" => iterator.max_iterations,
      "deps" => Enum.sort(iterator.deps)
    }

    maybe_put_provenance(base, iterator.provenance, registry, opts, path)
  end

  defp stored_node!(node, action_ids, registry, opts, path) do
    base = %{
      "name" => node.name,
      "action" => Map.fetch!(action_ids, node.action),
      "input" => ExpressionEncoder.encode!(node.input, path ++ ["input"], registry),
      "deps" => Enum.sort(node.deps)
    }

    maybe_put_provenance(base, node.provenance, registry, opts, path)
  end

  defp maybe_put_provenance(base, provenance, registry, opts, path) do
    if Keyword.get(opts, :provenance, false) do
      Map.put(
        base,
        "provenance",
        DataEncoder.encode!(provenance, path ++ ["provenance"], registry)
      )
    else
      base
    end
  end
end
