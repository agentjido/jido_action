defmodule Jido.Flow.MapCodec.Decoder do
  @moduledoc false

  alias Jido.Flow.MapCodec.DataCodec
  alias Jido.Flow.MapCodec.ErrorPath
  alias Jido.Flow.MapCodec.ExpressionCodec
  alias Jido.Flow.MapCodec.RecordValidator
  alias Jido.Flow.MapCodec.RegistryLookup
  alias Jido.Flow.Registry
  alias Jido.Flow.ResourceBudget

  @doc false
  def decode(%{} = map, %Registry{} = registry) do
    with :ok <- ResourceBudget.validate(map, :map),
         :ok <- RecordValidator.validate_root_header(map, :stored),
         :ok <- RecordValidator.validate_root(map, :stored),
         {:ok, decoded} <- decode_flow(map, :stored),
         {:ok, attrs} <- RegistryLookup.resolve(decoded, registry) do
      {:ok, attrs}
    end
  end

  defp decode_flow(map, profile) do
    with {:ok, name} <-
           RecordValidator.profile_fetch_required(
             map,
             :name,
             profile,
             "flow map name is required"
           ),
         {:ok, input_schema} <- decode_root_schema(map, :input_schema, profile),
         {:ok, output_schema} <- decode_root_schema(map, :output_schema, profile),
         {:ok, nodes} <-
           RecordValidator.profile_fetch_required(
             map,
             :nodes,
             profile,
             "flow map nodes are required"
           ),
         {:ok, return} <-
           RecordValidator.profile_fetch_required(
             map,
             :return,
             profile,
             "flow map return is required"
           ),
         {:ok, nodes} <- decode_nodes(nodes, profile),
         {:ok, return} <-
           ExpressionCodec.decode(return, profile)
           |> ErrorPath.prepend([RecordValidator.profile_field(:return, profile)]),
         {:ok, provenance} <-
           DataCodec.decode_optional(map, :provenance, %{}, profile)
           |> ErrorPath.prepend([RecordValidator.profile_field(:provenance, profile)]) do
      {:ok,
       %{
         name: name,
         description: RecordValidator.profile_fetch_optional(map, :description, nil, profile),
         schema: input_schema,
         output_schema: output_schema,
         nodes: nodes,
         return: return,
         provenance: provenance
       }}
    end
  end

  defp decode_root_schema(map, field, :stored) do
    RecordValidator.profile_fetch_required(map, field, :stored, "flow #{field} is required")
    |> then(fn
      {:ok, identifier} -> RegistryLookup.decode_identifier(identifier, :schema)
      {:error, error} -> {:error, error}
    end)
    |> ErrorPath.prepend([RecordValidator.profile_field(field, :stored)])
  end

  defp decode_nodes(nodes, profile) when is_list(nodes) do
    if List.improper?(nodes) do
      ErrorPath.error("flow nodes must be a list")
    else
      nodes
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {node, index}, {:ok, acc} ->
        case decode_node(node, profile)
             |> ErrorPath.prepend([RecordValidator.profile_field(:nodes, profile), index]) do
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

  defp decode_nodes(_nodes, _profile), do: ErrorPath.error("flow nodes must be a list")

  defp decode_node(%{} = node, profile) do
    case explicit_node_kind(node, profile) do
      {:ok, :choice} ->
        decode_choice(node, profile)

      {:ok, :map} ->
        decode_map(node, profile)

      {:ok, :reduce} ->
        decode_reduce(node, profile)

      {:ok, :iterate} ->
        decode_iterator(node, profile)

      {:error, kind} ->
        ErrorPath.error("unknown flow node kind: #{inspect(kind)}", %{kind: kind})

      :none ->
        if legacy_choice_record?(node, profile),
          do: decode_choice(node, profile),
          else: decode_action_node(node, profile)
    end
  end

  defp decode_node(_node, _profile), do: ErrorPath.error("flow node must be a map")

  defp decode_action_node(node, profile) do
    with :ok <- RecordValidator.validate_node_record(node, profile),
         {:ok, name} <-
           RecordValidator.profile_fetch_required(
             node,
             :name,
             profile,
             "flow node name is required"
           ),
         {:ok, action} <-
           RecordValidator.profile_fetch_required(
             node,
             :action,
             profile,
             "flow node action is required"
           ),
         {:ok, action} <-
           decode_action(action, profile)
           |> ErrorPath.prepend([RecordValidator.profile_field(:action, profile)]),
         {:ok, input} <-
           ExpressionCodec.decode(
             RecordValidator.profile_fetch_optional(node, :input, %{}, profile),
             profile
           )
           |> ErrorPath.prepend([RecordValidator.profile_field(:input, profile)]),
         {:ok, provenance} <-
           DataCodec.decode_optional(node, :provenance, %{}, profile)
           |> ErrorPath.prepend([RecordValidator.profile_field(:provenance, profile)]),
         {:ok, deps} <-
           decode_node_deps(RecordValidator.profile_fetch_optional(node, :deps, [], profile)) do
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

  defp decode_map(map, profile) do
    with :ok <- RecordValidator.validate_map_record(map, profile),
         {:ok, name} <-
           RecordValidator.profile_fetch_required(map, :name, profile, "map name is required"),
         {:ok, collection} <-
           RecordValidator.profile_fetch_required(
             map,
             :collection,
             profile,
             "map collection is required"
           ),
         {:ok, collection} <-
           ExpressionCodec.decode(collection, profile)
           |> ErrorPath.prepend([RecordValidator.profile_field(:collection, profile)]),
         {:ok, action} <-
           RecordValidator.profile_fetch_required(map, :action, profile, "map action is required"),
         {:ok, action} <-
           decode_action(action, profile)
           |> ErrorPath.prepend([RecordValidator.profile_field(:action, profile)]),
         {:ok, input} <-
           RecordValidator.profile_fetch_required(map, :input, profile, "map input is required"),
         {:ok, input} <-
           ExpressionCodec.decode(input, profile)
           |> ErrorPath.prepend([RecordValidator.profile_field(:input, profile)]),
         {:ok, on_error} <-
           RecordValidator.profile_fetch_required(
             map,
             :on_error,
             profile,
             "map on_error is required"
           ),
         {:ok, on_error} <-
           decode_map_error_mode(on_error, profile)
           |> ErrorPath.prepend([RecordValidator.profile_field(:on_error, profile)]),
         {:ok, deps} <-
           RecordValidator.profile_fetch_required(map, :deps, profile, "map deps are required"),
         {:ok, deps} <- decode_node_deps(deps),
         {:ok, provenance} <-
           DataCodec.decode_optional(map, :provenance, %{}, profile)
           |> ErrorPath.prepend([RecordValidator.profile_field(:provenance, profile)]) do
      {:ok,
       %{
         kind: :map,
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

  defp decode_reduce(reduce, profile) do
    with :ok <- RecordValidator.validate_reduce_record(reduce, profile),
         {:ok, name} <-
           RecordValidator.profile_fetch_required(
             reduce,
             :name,
             profile,
             "reduce name is required"
           ),
         {:ok, collection} <-
           RecordValidator.profile_fetch_required(
             reduce,
             :collection,
             profile,
             "reduce collection is required"
           ),
         {:ok, collection} <-
           ExpressionCodec.decode(collection, profile)
           |> ErrorPath.prepend([RecordValidator.profile_field(:collection, profile)]),
         {:ok, initial} <-
           RecordValidator.profile_fetch_required(
             reduce,
             :initial,
             profile,
             "reduce initial is required"
           ),
         {:ok, initial} <-
           ExpressionCodec.decode(initial, profile)
           |> ErrorPath.prepend([RecordValidator.profile_field(:initial, profile)]),
         {:ok, action} <-
           RecordValidator.profile_fetch_required(
             reduce,
             :action,
             profile,
             "reduce action is required"
           ),
         {:ok, action} <-
           decode_action(action, profile)
           |> ErrorPath.prepend([RecordValidator.profile_field(:action, profile)]),
         {:ok, input} <-
           RecordValidator.profile_fetch_required(
             reduce,
             :input,
             profile,
             "reduce input is required"
           ),
         {:ok, input} <-
           ExpressionCodec.decode(input, profile)
           |> ErrorPath.prepend([RecordValidator.profile_field(:input, profile)]),
         {:ok, deps} <-
           RecordValidator.profile_fetch_required(
             reduce,
             :deps,
             profile,
             "reduce deps are required"
           ),
         {:ok, deps} <- decode_node_deps(deps),
         {:ok, provenance} <-
           DataCodec.decode_optional(reduce, :provenance, %{}, profile)
           |> ErrorPath.prepend([RecordValidator.profile_field(:provenance, profile)]) do
      {:ok,
       %{
         kind: :reduce,
         name: name,
         collection: collection,
         initial: initial,
         action: action,
         input: input,
         deps: deps,
         provenance: provenance
       }}
    end
  end

  defp decode_iterator(iterator, profile) do
    with :ok <- RecordValidator.validate_iterator_record(iterator, profile),
         {:ok, name} <-
           RecordValidator.profile_fetch_required(
             iterator,
             :name,
             profile,
             "iterator name is required"
           ),
         {:ok, action} <-
           RecordValidator.profile_fetch_required(
             iterator,
             :action,
             profile,
             "iterator action is required"
           ),
         {:ok, action} <-
           decode_action(action, profile)
           |> ErrorPath.prepend([RecordValidator.profile_field(:action, profile)]),
         {:ok, input} <-
           RecordValidator.profile_fetch_required(
             iterator,
             :input,
             profile,
             "iterator input is required"
           ),
         {:ok, input} <-
           ExpressionCodec.decode(input, profile)
           |> ErrorPath.prepend([RecordValidator.profile_field(:input, profile)]),
         {:ok, state} <-
           RecordValidator.profile_fetch_required(
             iterator,
             :state,
             profile,
             "iterator state is required"
           ),
         {:ok, state} <-
           decode_iterator_state(state, profile)
           |> ErrorPath.prepend([RecordValidator.profile_field(:state, profile)]),
         {:ok, completion} <-
           RecordValidator.profile_fetch_required(
             iterator,
             :completion,
             profile,
             "iterator completion is required"
           ),
         {:ok, completion} <-
           ExpressionCodec.decode_condition(completion, profile, :iterate_completion)
           |> ErrorPath.prepend([RecordValidator.profile_field(:completion, profile)]),
         {:ok, max_iterations} <-
           RecordValidator.profile_fetch_required(
             iterator,
             :max_iterations,
             profile,
             "iterator max_iterations is required"
           ),
         {:ok, deps} <-
           RecordValidator.profile_fetch_required(
             iterator,
             :deps,
             profile,
             "iterator deps are required"
           ),
         {:ok, deps} <- decode_node_deps(deps),
         {:ok, provenance} <-
           DataCodec.decode_optional(iterator, :provenance, %{}, profile)
           |> ErrorPath.prepend([RecordValidator.profile_field(:provenance, profile)]) do
      {:ok,
       %{
         kind: :iterate,
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

  defp decode_iterator_state(%{} = state, profile) do
    with :ok <- RecordValidator.validate_iterator_state_record(state, profile),
         :ok <-
           validate_iterator_state_kind(
             RecordValidator.profile_fetch_optional(state, :kind, nil, profile),
             profile
           ),
         {:ok, version} <-
           RecordValidator.profile_fetch_required(
             state,
             :version,
             profile,
             "iterator state version is required"
           ),
         :ok <- validate_iterator_state_version(version),
         {:ok, schema} <-
           RecordValidator.profile_fetch_required(
             state,
             :schema,
             profile,
             "iterator state schema is required"
           ),
         {:ok, schema} <- decode_iterator_state_schema(schema, profile),
         {:ok, initial} <-
           RecordValidator.profile_fetch_required(
             state,
             :initial,
             profile,
             "iterator state initial is required"
           ),
         {:ok, initial} <-
           ExpressionCodec.decode(initial, profile)
           |> ErrorPath.prepend([RecordValidator.profile_field(:initial, profile)]),
         {:ok, update} <-
           RecordValidator.profile_fetch_required(
             state,
             :update,
             profile,
             "iterator state update is required"
           ),
         {:ok, update} <-
           ExpressionCodec.decode(update, profile)
           |> ErrorPath.prepend([RecordValidator.profile_field(:update, profile)]) do
      {:ok, %{version: version, schema: schema, initial: initial, update: update}}
    end
  end

  defp decode_iterator_state(_state, _profile),
    do: ErrorPath.error("iterator state must be a map")

  defp decode_iterator_state_schema(identifier, :stored) do
    RegistryLookup.decode_identifier(identifier, :schema)
  end

  defp validate_iterator_state_version(1), do: :ok

  defp validate_iterator_state_version(version) do
    ErrorPath.error("unsupported iterator state version: #{inspect(version)}", %{version: version})
  end

  defp validate_iterator_state_kind("iterate_state", :stored), do: :ok

  defp validate_iterator_state_kind(kind, _profile) do
    ErrorPath.error("iterate state kind must be iterate_state", %{kind: kind})
  end

  defp decode_choice(choice, profile) do
    with :ok <- RecordValidator.validate_choice_record(choice, profile),
         {:ok, name} <-
           RecordValidator.profile_fetch_required(
             choice,
             :name,
             profile,
             "choice name is required"
           ),
         {:ok, options} <-
           RecordValidator.profile_fetch_required(
             choice,
             :options,
             profile,
             "choice options are required"
           ),
         {:ok, options} <-
           decode_choice_options(options, profile)
           |> ErrorPath.prepend([RecordValidator.profile_field(:options, profile)]),
         {:ok, fallback} <-
           RecordValidator.profile_fetch_required(
             choice,
             :fallback,
             profile,
             "choice fallback is required"
           ),
         {:ok, fallback} <-
           decode_choice_fallback(fallback, profile)
           |> ErrorPath.prepend([RecordValidator.profile_field(:fallback, profile)]),
         {:ok, deps} <-
           decode_node_deps(RecordValidator.profile_fetch_optional(choice, :deps, [], profile)),
         {:ok, provenance} <-
           DataCodec.decode_optional(choice, :provenance, %{}, profile)
           |> ErrorPath.prepend([RecordValidator.profile_field(:provenance, profile)]) do
      {:ok,
       %{
         kind: :choice,
         name: name,
         options: options,
         fallback: fallback,
         deps: deps,
         provenance: provenance
       }}
    end
  end

  defp decode_choice_options(options, profile) when is_list(options) do
    if List.improper?(options) do
      ErrorPath.error("choice options must be a list")
    else
      options
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {option, index}, {:ok, acc} ->
        case decode_choice_option(option, profile)
             |> ErrorPath.prepend([index]) do
          {:ok, option} -> {:cont, {:ok, [option | acc]}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
      |> case do
        {:ok, options} -> {:ok, Enum.reverse(options)}
        {:error, error} -> {:error, error}
      end
    end
  end

  defp decode_choice_options(_options, _profile),
    do: ErrorPath.error("choice options must be a list")

  defp decode_choice_option(%{} = option, profile) do
    with :ok <- RecordValidator.validate_choice_option_record(option, profile),
         {:ok, name} <-
           RecordValidator.profile_fetch_required(
             option,
             :name,
             profile,
             "choice option name is required"
           ),
         {:ok, condition} <-
           RecordValidator.profile_fetch_required(
             option,
             :condition,
             profile,
             "choice option condition is required"
           ),
         {:ok, condition} <-
           ExpressionCodec.decode_condition(condition, profile)
           |> ErrorPath.prepend([RecordValidator.profile_field(:condition, profile)]),
         {:ok, action} <-
           RecordValidator.profile_fetch_required(
             option,
             :action,
             profile,
             "choice option action is required"
           ),
         {:ok, action} <-
           decode_action(action, profile)
           |> ErrorPath.prepend([RecordValidator.profile_field(:action, profile)]),
         {:ok, input} <-
           ExpressionCodec.decode(
             RecordValidator.profile_fetch_optional(option, :input, %{}, profile),
             profile
           )
           |> ErrorPath.prepend([RecordValidator.profile_field(:input, profile)]) do
      {:ok, %{name: name, condition: condition, action: action, input: input}}
    end
  end

  defp decode_choice_option(_option, _profile), do: ErrorPath.error("choice option must be a map")

  defp decode_choice_fallback(%{} = fallback, profile) do
    with :ok <- RecordValidator.validate_choice_fallback_record(fallback, profile),
         :ok <-
           validate_fallback_name(
             RecordValidator.profile_fetch_optional(fallback, :name, nil, profile),
             profile
           )
           |> ErrorPath.prepend([RecordValidator.profile_field(:name, profile)]),
         {:ok, action} <-
           RecordValidator.profile_fetch_required(
             fallback,
             :action,
             profile,
             "choice fallback action is required"
           ),
         {:ok, action} <-
           decode_action(action, profile)
           |> ErrorPath.prepend([RecordValidator.profile_field(:action, profile)]),
         {:ok, input} <-
           ExpressionCodec.decode(
             RecordValidator.profile_fetch_optional(fallback, :input, %{}, profile),
             profile
           )
           |> ErrorPath.prepend([RecordValidator.profile_field(:input, profile)]) do
      {:ok, %{action: action, input: input}}
    end
  end

  defp decode_choice_fallback(_fallback, _profile),
    do: ErrorPath.error("choice fallback must be a map")

  defp explicit_node_kind(node, :stored) do
    case Map.fetch(node, "kind") do
      {:ok, "choice"} -> {:ok, :choice}
      {:ok, "map"} -> {:ok, :map}
      {:ok, "reduce"} -> {:ok, :reduce}
      {:ok, "iterate"} -> {:ok, :iterate}
      {:ok, kind} -> {:error, kind}
      :error -> :none
    end
  end

  defp legacy_choice_record?(node, :stored),
    do: Map.has_key?(node, "options") or Map.has_key?(node, "fallback")

  defp decode_map_error_mode("fail_fast", :stored), do: {:ok, :fail_fast}
  defp decode_map_error_mode("collect_errors", :stored), do: {:ok, :collect_errors}

  defp decode_map_error_mode(mode, _profile) do
    ErrorPath.error("map on_error must be fail_fast or collect_errors", %{on_error: mode})
  end

  defp validate_fallback_name("fallback", :stored), do: :ok

  defp validate_fallback_name(_name, _profile),
    do: ErrorPath.error("choice fallback name must be fallback")

  defp decode_node_deps(deps) when is_list(deps) do
    if List.improper?(deps) do
      ErrorPath.error("flow node deps must be a list", %{deps: inspect(deps)})
    else
      {:ok, deps}
    end
  end

  defp decode_node_deps(deps), do: ErrorPath.error("flow node deps must be a list", %{deps: deps})

  defp decode_action(identifier, :stored) do
    RegistryLookup.decode_identifier(identifier, :action)
  end
end
