defmodule Jido.Flow.MapCodec do
  @moduledoc false

  alias Jido.Action.Error
  alias Jido.Flow.Node
  alias Jido.Flow.Ref

  @version 1
  @ref_types [:input, :context, :result, :value]
  @stored_ref_types ["input", "context", "result", "value"]
  @option_keys [:actions, :schema, :output_schema]
  @semantic_root_keys [
    :type,
    :version,
    :name,
    :description,
    :schema,
    :output_schema,
    :nodes,
    :return,
    :provenance
  ]
  @stored_root_keys [
    "type",
    "version",
    "name",
    "description",
    "nodes",
    "return",
    "provenance"
  ]

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
         :ok <- validate_option_keys(opts),
         {:ok, profile} <- select_profile(map),
         :ok <- validate_root(map, profile),
         :ok <- validate_root_header(map, profile),
         :ok <- validate_profile_options(opts, profile),
         {:ok, actions} <- profile_actions(opts, profile),
         {:ok, attrs} <- decode_flow(map, actions, opts, profile) do
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

  defp decode_flow(map, actions, opts, profile) do
    with {:ok, name} <- profile_fetch_required(map, :name, profile, "flow map name is required"),
         {:ok, nodes} <-
           profile_fetch_required(map, :nodes, profile, "flow map nodes are required"),
         {:ok, return} <-
           profile_fetch_required(map, :return, profile, "flow map return is required"),
         {:ok, nodes} <- decode_nodes(nodes, actions, profile),
         {:ok, return} <- decode_expression(return, profile),
         {:ok, provenance} <- decode_optional_data(map, :provenance, %{}, profile) do
      {:ok,
       %{
         name: name,
         description: profile_fetch_optional(map, :description, nil, profile),
         schema: profile_schema(map, opts, :schema, profile),
         output_schema: profile_schema(map, opts, :output_schema, profile),
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

  defp validate_type(:flow, :semantic), do: :ok
  defp validate_type("flow", :stored), do: :ok

  defp validate_type(type, _profile) do
    error("flow map type must be flow", %{type: type})
  end

  defp decode_nodes(nodes, actions, profile) when is_list(nodes) do
    if List.improper?(nodes) do
      error("flow nodes must be a list")
    else
      nodes
      |> Enum.reduce_while({:ok, []}, fn node, {:ok, acc} ->
        case decode_node(node, actions, profile) do
          {:ok, node} -> {:cont, {:ok, [node | acc]}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
      |> case do
        {:ok, nodes} -> {:ok, Enum.reverse(nodes)}
        {:error, error} -> {:error, error}
      end
    end
  end

  defp decode_nodes(_nodes, _actions, _profile), do: error("flow nodes must be a list")

  defp decode_node(%{} = node, actions, profile) do
    with :ok <- validate_node_record(node, profile),
         {:ok, name} <- profile_fetch_required(node, :name, profile, "flow node name is required"),
         {:ok, action} <-
           profile_fetch_required(node, :action, profile, "flow node action is required"),
         {:ok, action} <- decode_action(action, actions, profile),
         {:ok, input} <-
           decode_expression(profile_fetch_optional(node, :input, %{}, profile), profile),
         {:ok, provenance} <- decode_optional_data(node, :provenance, %{}, profile),
         {:ok, deps} <- decode_node_deps(profile_fetch_optional(node, :deps, [], profile)) do
      {:ok,
       %{
         name: name,
         action: action,
         input: input,
         deps: deps,
         provenance: provenance
       }}
    end
  end

  defp decode_node(_node, _actions, _profile), do: error("flow node must be a map")

  defp decode_node_deps(deps) when is_list(deps) do
    if List.improper?(deps) do
      error("flow node deps must be a list", %{deps: inspect(deps)})
    else
      {:ok, deps}
    end
  end

  defp decode_node_deps(deps), do: error("flow node deps must be a list", %{deps: deps})

  defp decode_action(action, _actions, :semantic) when is_atom(action) and not is_nil(action) do
    {:ok, action}
  end

  defp decode_action(identifier, actions, :stored) when is_binary(identifier) do
    case Map.fetch(actions, identifier) do
      {:ok, action} ->
        {:ok, action}

      :error ->
        error("unknown flow action identifier: #{inspect(identifier)}", %{
          identifier: identifier
        })
    end
  end

  defp decode_action(action, _actions, :semantic) do
    error("semantic flow node action must be a module atom", %{action: action})
  end

  defp decode_action(action, _actions, :stored) do
    error("stored flow node action must be a registered identifier", %{action: action})
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

  defp decode_expression(%{} = map, :semantic) do
    case semantic_ref_type(map) do
      {:ok, type} -> decode_ref(map, type, :semantic)
      {:error, error} -> {:error, error}
      :shape -> decode_shape_map(map, :semantic)
    end
  end

  defp decode_expression(%{} = map, :stored) do
    case Map.fetch(map, "type") do
      {:ok, "map"} ->
        decode_expression_map(map)

      {:ok, type} when type in @stored_ref_types ->
        decode_ref(map, type, :stored)

      {:ok, type} ->
        error("unknown flow ref type: #{inspect(type)}", %{type: type})

      :error ->
        error("stored flow expression must be a tagged record", %{record: :expression})
    end
  end

  defp decode_expression(list, profile) when is_list(list) do
    if List.improper?(list) do
      error("flow expression must be a proper list", %{expression: inspect(list)})
    else
      list
      |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
        case decode_expression(value, profile) do
          {:ok, value} -> {:cont, {:ok, [value | acc]}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
      |> case do
        {:ok, values} -> {:ok, Enum.reverse(values)}
        {:error, error} -> {:error, error}
      end
    end
  end

  defp decode_expression(value, :semantic), do: {:ok, value}

  defp decode_expression(value, :stored) do
    error("stored flow expression must be a tagged record", %{
      record: :expression,
      value: value
    })
  end

  defp semantic_ref_type(map) do
    case Map.fetch(map, :type) do
      {:ok, type} when type in @ref_types ->
        {:ok, type}

      {:ok, type} when is_atom(type) or is_binary(type) ->
        error("unknown flow ref type: #{inspect(type)}", %{type: type})

      {:ok, _shape_value} ->
        :shape

      :error ->
        :shape
    end
  end

  defp decode_ref(map, :input, :semantic) do
    with :ok <- validate_ref_record(map, :input, :semantic),
         {:ok, path} <- validate_semantic_path(Map.fetch!(map, :path)) do
      {:ok, Ref.input(path)}
    end
  end

  defp decode_ref(map, :context, :semantic) do
    with :ok <- validate_ref_record(map, :context, :semantic),
         {:ok, path} <- validate_semantic_path(Map.fetch!(map, :path)) do
      {:ok, Ref.context(path)}
    end
  end

  defp decode_ref(map, :result, :semantic) do
    with :ok <- validate_ref_record(map, :result, :semantic),
         {:ok, node} <- decode_result_node(Map.fetch!(map, :node), :semantic),
         {:ok, path} <- validate_semantic_path(Map.fetch!(map, :path)) do
      {:ok, Ref.result(node, path)}
    end
  end

  defp decode_ref(map, :value, :semantic) do
    with :ok <- validate_ref_record(map, :value, :semantic) do
      {:ok, Ref.value(Map.fetch!(map, :value))}
    end
  end

  defp decode_ref(map, "input", :stored) do
    with :ok <- validate_ref_record(map, "input", :stored),
         {:ok, path} <- decode_stored_path(Map.fetch!(map, "path")) do
      {:ok, Ref.input(path)}
    end
  end

  defp decode_ref(map, "context", :stored) do
    with :ok <- validate_ref_record(map, "context", :stored),
         {:ok, path} <- decode_stored_path(Map.fetch!(map, "path")) do
      {:ok, Ref.context(path)}
    end
  end

  defp decode_ref(map, "result", :stored) do
    with :ok <- validate_ref_record(map, "result", :stored),
         {:ok, node} <- decode_result_node(Map.fetch!(map, "node"), :stored),
         {:ok, path} <- decode_stored_path(Map.fetch!(map, "path")) do
      {:ok, Ref.result(node, path)}
    end
  end

  defp decode_ref(map, "value", :stored) do
    with :ok <- validate_ref_record(map, "value", :stored),
         {:ok, value} <- decode_data(Map.fetch!(map, "value")) do
      {:ok, Ref.value(value)}
    end
  end

  defp decode_expression_map(map) do
    with :ok <-
           validate_record(map, ["type", "entries"], ["type", "entries"], :encoded_map),
         {:ok, entries} <-
           exact_fetch_required(map, "entries", "flow expression map entries are required"),
         {:ok, entries} <- decode_entries(entries, &decode_expression(&1, :stored)) do
      {:ok, Map.new(entries)}
    end
  end

  defp decode_result_node(node, :semantic) when is_atom(node) and not is_nil(node),
    do: {:ok, node}

  defp decode_result_node(node, :semantic) when is_binary(node), do: {:ok, node}

  defp decode_result_node(node, :semantic) do
    error("semantic result ref node must be a non-nil atom or binary", %{node: node})
  end

  defp decode_result_node(node, :stored) when is_binary(node), do: {:ok, node}

  defp decode_result_node(node, :stored) do
    error("stored result ref node must be a binary", %{node: node})
  end

  defp decode_shape_map(map, profile) do
    map
    |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case decode_expression(value, profile) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp encode_path!(path), do: Enum.map(path, &encode_key!/1)

  defp decode_stored_path(path) when is_list(path) do
    if List.improper?(path) do
      error("flow ref path must be a list", %{path: inspect(path)})
    else
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

  defp decode_optional_data(map, field, default, :semantic) do
    {:ok, Map.get(map, field, default)}
  end

  defp decode_optional_data(map, field, default, :stored) do
    string_field = Atom.to_string(field)

    case Map.fetch(map, string_field) do
      {:ok, value} -> decode_data(value)
      :error -> {:ok, default}
    end
  end

  defp decode_data(%{} = map) do
    case Map.get(map, "$type") do
      "atom" ->
        with :ok <- validate_record(map, ["$type", "value"], ["$type", "value"], :encoded_value),
             {:ok, value} <- exact_fetch_required(map, "value", "encoded atom value is required"),
             {:ok, value} <- decode_encoded_atom_value(value) do
          existing_atom(value)
        end

      "map" ->
        with :ok <-
               validate_record(
                 map,
                 ["$type", "entries"],
                 ["$type", "entries"],
                 :encoded_map
               ),
             {:ok, entries} <-
               exact_fetch_required(map, "entries", "encoded map entries are required"),
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
    if List.improper?(list) do
      stored_data_error(list)
    else
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
  end

  defp decode_data(value)
       when is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value),
       do: {:ok, value}

  defp decode_data(value), do: stored_data_error(value)

  defp decode_plain_data_map(map) do
    case Enum.find(Map.keys(map), &(not is_binary(&1))) do
      nil ->
        map
        |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
          case decode_data(value) do
            {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
            {:error, error} -> {:halt, {:error, error}}
          end
        end)

      key ->
        error("stored plain data map contains a non-string key", %{
          record: :plain_data,
          key: key
        })
    end
  end

  defp decode_entries(entries, value_decoder) when is_list(entries) do
    if List.improper?(entries) do
      error("encoded map entries must be a list", %{entries: inspect(entries)})
    else
      entries
      |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
        case decode_entry(entry, value_decoder) do
          {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
      |> case do
        {:ok, entries} -> entries |> Enum.reverse() |> validate_unique_entries()
        {:error, error} -> {:error, error}
      end
    end
  end

  defp decode_entries(entries, _value_decoder) do
    error("encoded map entries must be a list", %{entries: entries})
  end

  defp decode_entry(%{} = entry, value_decoder) do
    with :ok <- validate_record(entry, ["key", "value"], ["key", "value"], :entry),
         {:ok, key} <- exact_fetch_required(entry, "key", "encoded map key is required"),
         {:ok, key} <- decode_key(key),
         {:ok, value} <- exact_fetch_required(entry, "value", "encoded map value is required"),
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
    with :ok <- validate_record(segment, ["type", "value"], ["type", "value"], :typed_key),
         {:ok, type} <- exact_fetch_required(segment, "type", "typed key type is required"),
         {:ok, value} <- exact_fetch_required(segment, "value", "typed key value is required") do
      decode_key(type, value)
    end
  end

  defp decode_key(segment) do
    error("malformed flow path segment", %{segment: segment})
  end

  defp decode_key("atom", value) when is_binary(value), do: existing_atom(value)
  defp decode_key("string", value) when is_binary(value), do: {:ok, value}
  defp decode_key("integer", value) when is_integer(value), do: {:ok, value}

  defp decode_key(type, value) do
    error("malformed flow path segment", %{type: type, value: value})
  end

  defp decode_encoded_atom_value(value) when is_binary(value), do: {:ok, value}

  defp decode_encoded_atom_value(value) do
    error("encoded atom value must be a binary", %{value: value})
  end

  defp existing_atom(value) when is_binary(value) do
    {:ok, String.to_existing_atom(value)}
  rescue
    ArgumentError ->
      error("unknown atom in flow map: #{inspect(value)}", %{value: value})
  end

  defp stored_data_error(value) do
    error("stored flow value is not JSON-safe", %{value: inspect(value)})
  end

  defp normalize_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      keys = Keyword.keys(opts)

      case first_duplicate(keys) do
        nil -> {:ok, Map.new(opts)}
        option -> error("duplicate flow map option: #{inspect(option)}", %{option: option})
      end
    else
      error("flow map options must be a map or keyword list")
    end
  end

  defp normalize_options(%{} = opts), do: {:ok, opts}

  defp normalize_options(_opts) do
    error("flow map options must be a map or keyword list")
  end

  defp validate_option_keys(opts) do
    case opts |> Map.keys() |> Enum.find(&(&1 not in @option_keys)) do
      nil -> :ok
      option -> error("unknown flow map option: #{inspect(option)}", %{option: option})
    end
  end

  defp select_profile(map) do
    cond do
      Map.has_key?(map, :type) -> {:ok, :semantic}
      Map.has_key?(map, "type") -> {:ok, :stored}
      true -> error("flow map type is required")
    end
  end

  defp validate_root(map, :semantic) do
    validate_record(
      map,
      @semantic_root_keys,
      [:schema, :output_schema],
      :root
    )
  end

  defp validate_root(map, :stored) do
    validate_record(
      map,
      @stored_root_keys,
      [],
      :root
    )
  end

  defp validate_root_header(map, profile) do
    with {:ok, version} <-
           profile_fetch_required(map, :version, profile, "flow map version is required"),
         :ok <- validate_version(version),
         {:ok, type} <- profile_fetch_required(map, :type, profile, "flow map type is required"),
         :ok <- validate_type(type, profile) do
      :ok
    end
  end

  defp validate_profile_options(opts, :semantic) when map_size(opts) == 0, do: :ok

  defp validate_profile_options(opts, :semantic) do
    option = opts |> Map.keys() |> Enum.sort() |> List.first()

    error("semantic flow maps do not accept loader options", %{
      option: option
    })
  end

  defp validate_profile_options(opts, :stored) do
    with :ok <- require_attachment(opts, :schema),
         :ok <- require_attachment(opts, :output_schema),
         :ok <- require_attachment(opts, :actions) do
      :ok
    end
  end

  defp require_attachment(opts, field) do
    case Map.fetch(opts, field) do
      {:ok, value} when not is_nil(value) or field == :actions ->
        :ok

      _missing_or_nil ->
        error("stored flow requires external #{field} attachment", %{field: field})
    end
  end

  defp profile_actions(_opts, :semantic), do: {:ok, %{}}
  defp profile_actions(opts, :stored), do: opts |> Map.fetch!(:actions) |> normalize_actions()

  defp validate_node_record(node, :semantic) do
    validate_record(
      node,
      [:name, :action, :input, :deps, :provenance],
      [:name, :action, :input, :deps],
      :node
    )
  end

  defp validate_node_record(node, :stored) do
    validate_record(
      node,
      ["name", "action", "input", "deps", "provenance"],
      ["name", "action", "input", "deps"],
      :node
    )
  end

  defp validate_ref_record(map, type, profile) do
    {allowed, required} = ref_fields(type, profile)
    validate_record(map, allowed, required, :reference)
  end

  defp ref_fields(type, :semantic) when type in [:input, :context],
    do: {[:type, :path], [:type, :path]}

  defp ref_fields(:result, :semantic),
    do: {[:type, :node, :path], [:type, :node, :path]}

  defp ref_fields(:value, :semantic), do: {[:type, :value], [:type, :value]}

  defp ref_fields(type, :stored) when type in ["input", "context"],
    do: {["type", "path"], ["type", "path"]}

  defp ref_fields("result", :stored),
    do: {["type", "node", "path"], ["type", "node", "path"]}

  defp ref_fields("value", :stored), do: {["type", "value"], ["type", "value"]}

  defp validate_record(map, allowed, required, record) do
    case map |> Map.keys() |> Enum.find(&(&1 not in allowed)) do
      nil ->
        case Enum.find(required, &(not Map.has_key?(map, &1))) do
          nil ->
            :ok

          field ->
            error("#{record} is missing required field: #{inspect(field)}", %{
              record: record,
              field: field
            })
        end

      field ->
        error("#{record} contains unknown field: #{inspect(field)}", %{
          record: record,
          field: field
        })
    end
  end

  defp validate_semantic_path(path) when is_list(path) do
    if List.improper?(path) do
      error("flow ref path must be a list", %{path: inspect(path)})
    else
      case Enum.find(path, &(not valid_path_segment?(&1))) do
        nil -> {:ok, path}
        segment -> error("flow ref path contains an invalid segment", %{segment: segment})
      end
    end
  end

  defp validate_semantic_path(path), do: error("flow ref path must be a list", %{path: path})

  defp valid_path_segment?(segment) do
    (is_atom(segment) and not is_nil(segment)) or is_binary(segment) or is_integer(segment)
  end

  defp validate_unique_entries(entries) do
    case entries |> Enum.map(&elem(&1, 0)) |> first_duplicate() do
      nil -> {:ok, entries}
      key -> error("encoded map contains a duplicate key", %{key: key})
    end
  end

  defp first_duplicate(values) do
    values
    |> Enum.reduce_while(MapSet.new(), fn value, seen ->
      if MapSet.member?(seen, value) do
        {:halt, {:duplicate, value}}
      else
        {:cont, MapSet.put(seen, value)}
      end
    end)
    |> case do
      {:duplicate, value} -> value
      %MapSet{} -> nil
    end
  end

  defp exact_fetch_required(map, field, message) do
    case Map.fetch(map, field) do
      {:ok, value} -> {:ok, value}
      :error -> error(message)
    end
  end

  defp profile_fetch_required(map, field, :semantic, message),
    do: exact_fetch_required(map, field, message)

  defp profile_fetch_required(map, field, :stored, message),
    do: exact_fetch_required(map, Atom.to_string(field), message)

  defp profile_fetch_optional(map, field, default, :semantic), do: Map.get(map, field, default)

  defp profile_fetch_optional(map, field, default, :stored),
    do: Map.get(map, Atom.to_string(field), default)

  defp profile_schema(map, _opts, field, :semantic), do: Map.fetch!(map, field)
  defp profile_schema(_map, opts, field, :stored), do: Map.fetch!(opts, field)

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

    identifiers_by_module =
      Enum.reduce(actions, %{}, fn {identifier, action}, acc ->
        Map.update(acc, action, [identifier], &[identifier | &1])
      end)

    Map.new(modules, fn module ->
      identifiers = Map.get(identifiers_by_module, module, [])

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

  defp key_sort_key(key) when is_atom(key), do: {0, Atom.to_string(key)}
  defp key_sort_key(key) when is_binary(key), do: {1, key}
  defp key_sort_key(key) when is_integer(key), do: {2, key}
  defp key_sort_key(key), do: {3, inspect(key)}

  defp error(message, details \\ %{}), do: {:error, Error.validation_error(message, details)}

  defp raise_validation(message, details) do
    raise Error.validation_error(message, details)
  end
end
