defmodule Jido.Flow.MapCodec do
  @moduledoc false

  alias Jido.Action.Error
  alias Jido.Flow.Node
  alias Jido.Flow.Ref

  @version 1
  @ref_types [:input, :context, :result, :value]
  @stored_ref_types ["input", "context", "result", "value"]

  @spec to_semantic_map(Jido.Flow.t(), [Node.t()], keyword()) :: map()
  def to_semantic_map(flow, ordered_nodes, opts) do
    base = %{
      type: :flow,
      version: @version,
      name: flow.name,
      description: flow.description,
      schema: flow.schema,
      output_schema: flow.output_schema,
      nodes: Enum.map(ordered_nodes, &Node.to_map(&1, opts)),
      return: Node.expression_to_map(flow.return)
    }

    if Keyword.get(opts, :provenance, false) do
      Map.put(base, :provenance, flow.provenance)
    else
      base
    end
  end

  @spec to_stored_map!(Jido.Flow.t(), [Node.t()], keyword()) :: map()
  def to_stored_map!(flow, ordered_nodes, opts) do
    actions =
      opts
      |> Keyword.get(:actions, %{})
      |> normalize_actions!()

    action_ids = action_ids!(actions, ordered_nodes)

    base = %{
      "type" => "flow",
      "version" => @version,
      "name" => flow.name,
      "description" => flow.description,
      "nodes" => Enum.map(ordered_nodes, &stored_node!(&1, action_ids, opts)),
      "return" => encode_expression!(flow.return)
    }

    if Keyword.get(opts, :provenance, false) do
      Map.put(base, "provenance", encode_data!(flow.provenance))
    else
      base
    end
  end

  @spec from_map(map(), map() | keyword()) :: {:ok, Jido.Flow.t()} | {:error, Exception.t()}
  def from_map(%{} = map, opts) do
    with {:ok, opts} <- normalize_options(opts),
         {:ok, actions} <- normalize_actions(Map.get(opts, :actions, %{})),
         {:ok, attrs} <- decode_flow(map, actions, opts) do
      Jido.Flow.new(attrs)
    end
  end

  def from_map(_map, _opts), do: error("flow map must be a map")

  defp stored_node!(node, action_ids, opts) do
    base = %{
      "name" => node.name,
      "action" => Map.fetch!(action_ids, node.action),
      "input" => encode_expression!(node.input),
      "deps" => Enum.sort(node.deps)
    }

    if Keyword.get(opts, :provenance, false) do
      Map.put(base, "provenance", encode_data!(node.provenance))
    else
      base
    end
  end

  defp decode_flow(map, actions, opts) do
    with {:ok, version} <- fetch_required(map, :version, "flow map version is required"),
         :ok <- validate_version(version),
         {:ok, type} <- fetch_required(map, :type, "flow map type is required"),
         :ok <- validate_type(type),
         {:ok, name} <- fetch_required(map, :name, "flow map name is required"),
         {:ok, nodes} <- fetch_required(map, :nodes, "flow map nodes are required"),
         {:ok, return} <- fetch_required(map, :return, "flow map return is required"),
         {:ok, nodes} <- decode_nodes(nodes, actions),
         {:ok, return} <- decode_expression(return),
         {:ok, provenance} <- decode_optional_data(map, :provenance, %{}) do
      {:ok,
       %{
         name: name,
         description: fetch_optional(map, :description, nil),
         schema: option_or_map_value(opts, map, :schema, []),
         output_schema: option_or_map_value(opts, map, :output_schema, []),
         nodes: nodes,
         return: return,
         provenance: provenance
       }}
    end
  end

  defp validate_version(@version), do: :ok

  defp validate_version(version) do
    error("unsupported flow map version: #{inspect(version)}", %{version: version})
  end

  defp validate_type(:flow), do: :ok
  defp validate_type("flow"), do: :ok

  defp validate_type(type) do
    error("flow map type must be flow", %{type: type})
  end

  defp decode_nodes(nodes, actions) when is_list(nodes) do
    nodes
    |> Enum.reduce_while({:ok, []}, fn node, {:ok, acc} ->
      case decode_node(node, actions) do
        {:ok, node} -> {:cont, {:ok, [node | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, nodes} -> {:ok, Enum.reverse(nodes)}
      {:error, error} -> {:error, error}
    end
  end

  defp decode_nodes(_nodes, _actions), do: error("flow nodes must be a list")

  defp decode_node(%{} = node, actions) do
    with {:ok, name} <- fetch_required(node, :name, "flow node name is required"),
         {:ok, action} <- fetch_required(node, :action, "flow node action is required"),
         {:ok, action} <- decode_action(action, actions),
         {:ok, input} <- decode_expression(fetch_optional(node, :input, %{})),
         {:ok, provenance} <- decode_optional_data(node, :provenance, %{}) do
      {:ok,
       %{
         name: name,
         action: action,
         input: input,
         deps: fetch_optional(node, :deps, []),
         provenance: provenance
       }}
    end
  end

  defp decode_node(_node, _actions), do: error("flow node must be a map")

  defp decode_action(action, _actions) when is_atom(action) and not is_nil(action) do
    {:ok, action}
  end

  defp decode_action(identifier, actions) when is_binary(identifier) do
    case Map.fetch(actions, identifier) do
      {:ok, action} ->
        {:ok, action}

      :error ->
        error("unknown flow action identifier: #{inspect(identifier)}", %{
          identifier: identifier
        })
    end
  end

  defp decode_action(action, _actions) do
    error("flow node action must be a module atom or registered identifier", %{action: action})
  end

  defp encode_expression!(%Ref{type: :input, path: path}) do
    %{"type" => "input", "path" => encode_path!(path)}
  end

  defp encode_expression!(%Ref{type: :context, path: path}) do
    %{"type" => "context", "path" => encode_path!(path)}
  end

  defp encode_expression!(%Ref{type: :result, node: node, path: path}) do
    %{"type" => "result", "node" => node, "path" => encode_path!(path)}
  end

  defp encode_expression!(%Ref{type: :value, value: value}) do
    %{"type" => "value", "value" => encode_data!(value)}
  end

  defp encode_expression!(%{} = map) when not is_struct(map) do
    %{
      "type" => "map",
      "entries" =>
        map
        |> Enum.sort_by(fn {key, _value} -> key_sort_key(key) end)
        |> Enum.map(fn {key, value} ->
          %{"key" => encode_key!(key), "value" => encode_expression!(value)}
        end)
    }
  end

  defp encode_expression!(list) when is_list(list), do: Enum.map(list, &encode_expression!/1)
  defp encode_expression!(value), do: value |> Ref.value() |> encode_expression!()

  defp decode_expression(%{} = map) do
    case ref_type(map) do
      {:ok, :stored_map} ->
        decode_expression_map(map)

      {:ok, type} when type in @ref_types ->
        decode_ref(map, type, :semantic)

      {:ok, type} when type in @stored_ref_types ->
        decode_ref(map, type, :stored)

      {:error, error} ->
        {:error, error}

      :shape ->
        decode_shape_map(map)
    end
  end

  defp decode_expression(list) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case decode_expression(value) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, error} -> {:error, error}
    end
  end

  defp decode_expression(value), do: {:ok, value}

  defp ref_type(map) do
    case fetch_optional_marker(map, :type) do
      nil ->
        :shape

      "map" ->
        {:ok, :stored_map}

      type when type in @ref_types or type in @stored_ref_types ->
        {:ok, type}

      type when is_atom(type) or is_binary(type) ->
        error("unknown flow ref type: #{inspect(type)}", %{type: type})

      _other ->
        :shape
    end
  end

  defp decode_ref(map, :input, :semantic) do
    {:ok, Ref.input(fetch_optional(map, :path, []))}
  end

  defp decode_ref(map, :context, :semantic) do
    {:ok, Ref.context(fetch_optional(map, :path, []))}
  end

  defp decode_ref(map, :result, :semantic) do
    with {:ok, node} <- fetch_required(map, :node, "result ref node is required") do
      {:ok, Ref.result(node, fetch_optional(map, :path, []))}
    end
  end

  defp decode_ref(map, :value, :semantic) do
    {:ok, Ref.value(fetch_optional(map, :value, nil))}
  end

  defp decode_ref(map, "input", :stored) do
    with {:ok, path} <- decode_stored_path(fetch_optional(map, :path, [])) do
      {:ok, Ref.input(path)}
    end
  end

  defp decode_ref(map, "context", :stored) do
    with {:ok, path} <- decode_stored_path(fetch_optional(map, :path, [])) do
      {:ok, Ref.context(path)}
    end
  end

  defp decode_ref(map, "result", :stored) do
    with {:ok, node} <- fetch_required(map, :node, "result ref node is required"),
         {:ok, path} <- decode_stored_path(fetch_optional(map, :path, [])) do
      {:ok, Ref.result(node, path)}
    end
  end

  defp decode_ref(map, "value", :stored) do
    with {:ok, value} <- decode_data(fetch_optional(map, :value, nil)) do
      {:ok, Ref.value(value)}
    end
  end

  defp decode_expression_map(map) do
    with {:ok, entries} <-
           fetch_required(map, :entries, "flow expression map entries are required"),
         {:ok, entries} <- decode_entries(entries, &decode_expression/1) do
      {:ok, Map.new(entries)}
    end
  end

  defp decode_shape_map(map) do
    map
    |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case decode_expression(value) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp encode_path!(path), do: Enum.map(path, &encode_key!/1)

  defp decode_stored_path(path) when is_list(path) do
    path
    |> Enum.reduce_while({:ok, []}, fn segment, {:ok, acc} ->
      case decode_key(segment) do
        {:ok, segment} -> {:cont, {:ok, [segment | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, path} -> {:ok, Enum.reverse(path)}
      {:error, error} -> {:error, error}
    end
  end

  defp decode_stored_path(path), do: error("flow ref path must be a list", %{path: path})

  defp encode_data!(value)
       when is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value),
       do: value

  defp encode_data!(value) when is_atom(value) do
    %{"$type" => "atom", "value" => Atom.to_string(value)}
  end

  defp encode_data!(list) when is_list(list), do: Enum.map(list, &encode_data!/1)

  defp encode_data!(%{} = map) when not is_struct(map) do
    %{
      "$type" => "map",
      "entries" =>
        map
        |> Enum.sort_by(fn {key, _value} -> key_sort_key(key) end)
        |> Enum.map(fn {key, value} ->
          %{"key" => encode_key!(key), "value" => encode_data!(value)}
        end)
    }
  end

  defp encode_data!(%{__struct__: module}) do
    raise_validation("stored flow value contains unsupported struct", %{struct: module})
  end

  defp encode_data!(value) do
    raise_validation("stored flow value is not JSON-safe", %{value: inspect(value)})
  end

  defp decode_optional_data(map, field, default) do
    if has_field?(map, field) do
      map
      |> fetch_optional(field, default)
      |> decode_data()
    else
      {:ok, default}
    end
  end

  defp decode_data(%{} = map) do
    case fetch_optional_marker(map, "$type") do
      "atom" ->
        with {:ok, value} <- fetch_required(map, :value, "encoded atom value is required") do
          existing_atom(value)
        end

      "map" ->
        with {:ok, entries} <- fetch_required(map, :entries, "encoded map entries are required"),
             {:ok, entries} <- decode_entries(entries, &decode_data/1) do
          {:ok, Map.new(entries)}
        end

      nil ->
        decode_plain_data_map(map)

      type ->
        error("unknown encoded value type: #{inspect(type)}", %{type: type})
    end
  end

  defp decode_data(list) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case decode_data(value) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, error} -> {:error, error}
    end
  end

  defp decode_data(value), do: {:ok, value}

  defp decode_plain_data_map(map) do
    map
    |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case decode_data(value) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp decode_entries(entries, value_decoder) when is_list(entries) do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case decode_entry(entry, value_decoder) do
        {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      {:error, error} -> {:error, error}
    end
  end

  defp decode_entries(entries, _value_decoder) do
    error("encoded map entries must be a list", %{entries: entries})
  end

  defp decode_entry(%{} = entry, value_decoder) do
    with {:ok, key} <- fetch_required(entry, :key, "encoded map key is required"),
         {:ok, key} <- decode_key(key),
         {:ok, value} <- fetch_required(entry, :value, "encoded map value is required"),
         {:ok, value} <- value_decoder.(value) do
      {:ok, {key, value}}
    end
  end

  defp decode_entry(entry, _value_decoder) do
    error("encoded map entry must be a map", %{entry: entry})
  end

  defp encode_key!(key) when is_atom(key) and not is_nil(key) do
    %{"type" => "atom", "value" => Atom.to_string(key)}
  end

  defp encode_key!(key) when is_binary(key), do: %{"type" => "string", "value" => key}
  defp encode_key!(key) when is_integer(key), do: %{"type" => "integer", "value" => key}

  defp encode_key!(key) do
    raise_validation("stored flow map key is not JSON-safe", %{key: inspect(key)})
  end

  defp decode_key(%{} = segment) do
    with {:ok, type} <- fetch_required(segment, :type, "typed key type is required"),
         {:ok, value} <- fetch_required(segment, :value, "typed key value is required") do
      decode_key(type, value)
    end
  end

  defp decode_key(segment) do
    error("malformed flow path segment", %{segment: segment})
  end

  defp decode_key("atom", value) when is_binary(value), do: existing_atom(value)
  defp decode_key(:atom, value) when is_binary(value), do: existing_atom(value)
  defp decode_key("string", value) when is_binary(value), do: {:ok, value}
  defp decode_key(:string, value) when is_binary(value), do: {:ok, value}
  defp decode_key("integer", value) when is_integer(value), do: {:ok, value}
  defp decode_key(:integer, value) when is_integer(value), do: {:ok, value}

  defp decode_key(type, value) do
    error("malformed flow path segment", %{type: type, value: value})
  end

  defp existing_atom(value) when is_binary(value) do
    {:ok, String.to_existing_atom(value)}
  rescue
    ArgumentError ->
      error("unknown atom in flow map: #{inspect(value)}", %{value: value})
  end

  defp normalize_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      {:ok, Map.new(opts)}
    else
      error("flow map options must be a map or keyword list")
    end
  end

  defp normalize_options(%{} = opts), do: {:ok, opts}

  defp normalize_options(_opts) do
    error("flow map options must be a map or keyword list")
  end

  defp normalize_actions!(actions) do
    case normalize_actions(actions) do
      {:ok, actions} -> actions
      {:error, error} -> raise error
    end
  end

  defp normalize_actions(actions) when is_list(actions) do
    if Keyword.keyword?(actions) do
      reduce_action_pairs(actions, actions)
    else
      action_registry_error(actions)
    end
  end

  defp normalize_actions(%{} = actions), do: reduce_action_pairs(actions, actions)
  defp normalize_actions(actions), do: action_registry_error(actions)

  defp reduce_action_pairs(actions, original_actions) do
    Enum.reduce_while(actions, {:ok, %{}}, fn
      {identifier, action}, {:ok, acc}
      when (is_binary(identifier) or (is_atom(identifier) and not is_nil(identifier))) and
             is_atom(action) and not is_nil(action) ->
        identifier = identifier_to_string(identifier)

        if Map.has_key?(acc, identifier) do
          {:halt,
           error("duplicate flow action registry identifier: #{inspect(identifier)}", %{
             identifier: identifier
           })}
        else
          {:cont, {:ok, Map.put(acc, identifier, action)}}
        end

      {_identifier, _action}, {:ok, _acc} ->
        {:halt, action_registry_error(original_actions)}
    end)
  end

  defp action_registry_error(actions) do
    error("flow action registry must map string or atom identifiers to modules", %{
      actions: actions
    })
  end

  defp action_ids!(actions, nodes) do
    modules = nodes |> Enum.map(& &1.action) |> Enum.uniq()

    Map.new(modules, fn module ->
      identifiers =
        actions
        |> Enum.filter(fn {_identifier, action} -> action == module end)
        |> Enum.map(fn {identifier, _action} -> identifier end)

      case identifiers do
        [identifier] ->
          {module, identifier}

        [] ->
          raise_validation("missing flow action registry identifier", %{action: module})

        identifiers ->
          raise_validation("ambiguous flow action registry identifiers", %{
            action: module,
            identifiers: Enum.sort(identifiers)
          })
      end
    end)
  end

  defp identifier_to_string(identifier) when is_atom(identifier), do: Atom.to_string(identifier)
  defp identifier_to_string(identifier), do: identifier

  defp fetch_required(map, field, message) do
    if has_field?(map, field) do
      {:ok, fetch_optional(map, field, nil)}
    else
      error(message)
    end
  end

  defp fetch_optional(map, field, default) when is_atom(field) do
    string_field = Atom.to_string(field)

    cond do
      Map.has_key?(map, field) -> Map.fetch!(map, field)
      Map.has_key?(map, string_field) -> Map.fetch!(map, string_field)
      true -> default
    end
  end

  defp fetch_optional(map, field, default) when is_binary(field) do
    cond do
      Map.has_key?(map, field) -> Map.fetch!(map, field)
      true -> default
    end
  end

  defp fetch_optional_marker(map, field) when is_atom(field), do: fetch_optional(map, field, nil)

  defp fetch_optional_marker(map, field) when is_binary(field),
    do: fetch_optional(map, field, nil)

  defp has_field?(map, field) when is_atom(field) do
    Map.has_key?(map, field) or Map.has_key?(map, Atom.to_string(field))
  end

  defp has_field?(map, field) when is_binary(field), do: Map.has_key?(map, field)

  defp option_or_map_value(opts, map, field, default) do
    if Map.has_key?(opts, field) do
      Map.fetch!(opts, field)
    else
      fetch_optional(map, field, default)
    end
  end

  defp key_sort_key(key) when is_atom(key), do: {0, Atom.to_string(key)}
  defp key_sort_key(key) when is_binary(key), do: {1, key}
  defp key_sort_key(key) when is_integer(key), do: {2, key}
  defp key_sort_key(key), do: {3, inspect(key)}

  defp error(message, details \\ %{}), do: {:error, Error.validation_error(message, details)}

  defp raise_validation(message, details) do
    raise Error.validation_error(message, details)
  end
end
