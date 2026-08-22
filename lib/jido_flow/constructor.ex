defmodule Jido.Flow.Constructor do
  @moduledoc false

  alias Jido.Action.Error
  alias Jido.Flow
  alias Jido.Flow.{Choice, Condition, Iterator, Node, Reduce, Ref}
  alias Jido.Flow.Map, as: FlowMap

  @node_kinds [:step, :choice, :map, :reduce, :iterate]

  @spec build(map() | keyword()) :: {:ok, Flow.t()} | {:error, Exception.t()}
  def build(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs), do: attrs |> Map.new() |> build(), else: invalid_attributes()
  end

  def build(%{} = attrs) do
    with {:ok, specs} <- fetch_node_specs(attrs),
         {:ok, nodes} <- build_nodes(specs),
         {:ok, return} <- build_return(Map.get(attrs, :return), nodes) do
      attrs
      |> Map.drop([:node_specs])
      |> Map.put(:nodes, nodes)
      |> Map.put(:return, return)
      |> Flow.new()
    end
  end

  def build(_attrs), do: invalid_attributes()

  defp fetch_node_specs(%{node_specs: specs}) when is_list(specs), do: {:ok, specs}
  defp fetch_node_specs(%{nodes: specs}) when is_list(specs), do: {:ok, specs}

  defp fetch_node_specs(_attrs) do
    {:error, Error.validation_error("flow nodes must be a list", %{path: [:nodes]})}
  end

  defp build_nodes(specs) do
    specs
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {spec, index}, {:ok, nodes} ->
      case build_node(spec) do
        {:ok, node} -> {:cont, {:ok, [node | nodes]}}
        {:error, error} -> {:halt, {:error, prefix_path(error, [:nodes, index])}}
      end
    end)
    |> reverse_ok()
  end

  defp build_node(%Node{} = node), do: Node.new(node)
  defp build_node(%Choice{} = choice), do: Choice.new(choice)
  defp build_node(%FlowMap{} = map), do: FlowMap.new(map)
  defp build_node(%Reduce{} = reduce), do: Reduce.new(reduce)
  defp build_node(%Iterator{} = iterator), do: Iterator.new(iterator)

  defp build_node(%{} = spec) do
    with {:ok, kind} <- fetch_kind(spec),
         :ok <- validate_spec_keys(spec, kind),
         {:ok, attrs} <- common_node_attrs(spec) do
      build_node_kind(kind, spec, attrs)
    end
  end

  defp build_node(spec) do
    {:error, Error.validation_error("flow node specification must be a map", %{value: spec})}
  end

  defp fetch_kind(%{kind: kind}) when kind in @node_kinds, do: {:ok, kind}

  defp fetch_kind(%{kind: kind}) do
    {:error,
     Error.validation_error("unsupported flow node kind: #{inspect(kind)}", %{kind: kind})}
  end

  defp fetch_kind(_spec) do
    {:error, Error.validation_error("flow node kind is required", %{path: [:kind]})}
  end

  defp validate_spec_keys(%{__builder_options_error__: options}, _kind) do
    {:error,
     Error.validation_error("Builder node options must be a keyword list with unique keys", %{
       options: options,
       path: [:options]
     })}
  end

  defp validate_spec_keys(spec, kind) do
    common = [:kind, :name, :after, :deps, :meta, :provenance]

    kind_keys = %{
      step: [:action, :input, :params],
      choice: [:options, :fallback],
      map: [:collection, :action, :input, :params, :on_error],
      reduce: [:collection, :initial, :action, :input, :params],
      iterate: [
        :action,
        :input,
        :params,
        :state,
        :completion,
        :while,
        :until,
        :repeat,
        :max_iterations
      ]
    }

    case Enum.find(Map.keys(spec), &(&1 not in (common ++ Map.fetch!(kind_keys, kind)))) do
      nil ->
        :ok

      key ->
        {:error,
         Error.validation_error("unknown #{kind} configuration key: #{inspect(key)}", %{
           key: key,
           path: [key]
         })}
    end
  end

  defp common_node_attrs(spec) do
    with {:ok, deps} <- normalize_after(Map.get(spec, :after, Map.get(spec, :deps, []))),
         {:ok, provenance} <- normalize_provenance(spec) do
      {:ok,
       %{
         name: Map.get(spec, :name),
         deps: deps,
         provenance: provenance
       }}
    end
  end

  defp build_node_kind(:step, spec, attrs) do
    Node.new(
      Map.merge(attrs, %{
        action: Map.get(spec, :action),
        input: Map.get(spec, :input, Map.get(spec, :params, %{}))
      })
    )
  end

  defp build_node_kind(:choice, spec, attrs) do
    Choice.new(
      Map.merge(attrs, %{
        options: Map.get(spec, :options),
        fallback: Map.get(spec, :fallback)
      })
    )
  end

  defp build_node_kind(:map, spec, attrs) do
    FlowMap.new(
      Map.merge(attrs, %{
        collection: Map.get(spec, :collection),
        action: Map.get(spec, :action),
        input: Map.get(spec, :input, Map.get(spec, :params, %{})),
        on_error: Map.get(spec, :on_error, :fail_fast)
      })
    )
  end

  defp build_node_kind(:reduce, spec, attrs) do
    Reduce.new(
      Map.merge(attrs, %{
        collection: Map.get(spec, :collection),
        initial: Map.get(spec, :initial),
        action: Map.get(spec, :action),
        input: Map.get(spec, :input, Map.get(spec, :params, %{}))
      })
    )
  end

  defp build_node_kind(:iterate, spec, attrs) do
    with {:ok, state} <- normalize_state(Map.get(spec, :state)),
         {:ok, completion, max_iterations} <- normalize_termination(spec) do
      Iterator.new(
        Map.merge(attrs, %{
          action: Map.get(spec, :action),
          input: Map.get(spec, :input, Map.get(spec, :params, %{})),
          state: state,
          completion: completion,
          max_iterations: max_iterations
        })
      )
    end
  end

  defp normalize_state(%{} = state) when not is_struct(state) do
    {:ok, Map.put_new(state, :update, Ref.body_result())}
  end

  defp normalize_state(state) when is_list(state) do
    if Keyword.keyword?(state),
      do: state |> Map.new() |> normalize_state(),
      else: {:error, Error.validation_error("iterator state configuration must be a map")}
  end

  defp normalize_state(state), do: {:ok, state}

  defp normalize_termination(%{completion: completion, max_iterations: max_iterations}) do
    {:ok, completion, max_iterations}
  end

  defp normalize_termination(spec) do
    forms = Enum.filter([:while, :until, :repeat], &Map.has_key?(spec, &1))

    case forms do
      [:until] ->
        termination_with_limit(Map.fetch!(spec, :until), Map.get(spec, :max_iterations))

      [:while] ->
        completion = %Condition{operator: :not, operands: [Map.fetch!(spec, :while)]}
        termination_with_limit(completion, Map.get(spec, :max_iterations))

      [:repeat] ->
        repeat_termination(Map.fetch!(spec, :repeat), Map.has_key?(spec, :max_iterations))

      _forms ->
        {:error,
         Error.validation_error("iterate requires exactly one of while, until, or repeat")}
    end
  end

  defp termination_with_limit(completion, max_iterations)
       when is_integer(max_iterations) and max_iterations in 1..10_000 do
    {:ok, completion, max_iterations}
  end

  defp termination_with_limit(_completion, _max_iterations) do
    {:error,
     Error.validation_error("iterate max_iterations must be an integer from 1 to 10000", %{
       path: [:max_iterations]
     })}
  end

  defp repeat_termination(_count, true) do
    {:error,
     Error.validation_error("iterate with repeat must not set max_iterations", %{
       path: [:max_iterations]
     })}
  end

  defp repeat_termination(count, false) when is_integer(count) and count in 1..10_000 do
    completion = %Condition{
      operator: :gte,
      operands: [Ref.iteration_index(), Ref.value(count)]
    }

    {:ok, completion, count}
  end

  defp repeat_termination(_count, false) do
    {:error,
     Error.validation_error("iterate repeat count must be an integer from 1 to 10000", %{
       path: [:repeat]
     })}
  end

  defp normalize_after(nil), do: {:ok, []}
  defp normalize_after(after_targets) when is_list(after_targets), do: {:ok, after_targets}
  defp normalize_after(after_target), do: {:ok, [after_target]}

  defp normalize_provenance(spec) do
    provenance = Map.get(spec, :provenance, Map.get(spec, :meta, %{}))

    if is_map(provenance) do
      {:ok, provenance}
    else
      {:error, Error.validation_error("flow node metadata must be a map", %{path: [:meta]})}
    end
  end

  defp build_return(nil, []),
    do: {:error, Error.validation_error("Flow must declare at least one node")}

  defp build_return(nil, nodes),
    do: {:ok, nodes |> List.last() |> Map.fetch!(:name) |> Ref.result()}

  defp build_return(return, _nodes), do: {:ok, return}

  defp reverse_ok({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_ok({:error, error}), do: {:error, error}

  defp prefix_path(%{details: details} = error, prefix) when is_map(details) do
    %{error | details: Map.put(details, :path, prefix ++ Map.get(details, :path, []))}
  end

  defp prefix_path(error, _prefix), do: error

  defp invalid_attributes do
    {:error, Error.validation_error("flow construction attributes must be a map or keyword list")}
  end
end
