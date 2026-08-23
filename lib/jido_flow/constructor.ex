defmodule Jido.Flow.Constructor do
  @moduledoc false

  alias Jido.Action.Error
  alias Jido.Flow
  alias Jido.Flow.{Choice, Iterator, Node, Reduce, Ref}
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
      |> Map.put(:nodes, nodes)
      |> Map.put(:return, return)
      |> Flow.new()
    end
  end

  def build(_attrs), do: invalid_attributes()

  defp fetch_node_specs(%{nodes: specs}) when is_list(specs), do: validate_node_specs(specs)

  defp fetch_node_specs(_attrs) do
    {:error, Error.validation_error("flow nodes must be a list", %{path: [:nodes]})}
  end

  defp validate_node_specs(specs) do
    if List.improper?(specs) do
      {:error, Error.validation_error("flow nodes must be a proper list", %{path: [:nodes]})}
    else
      {:ok, specs}
    end
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

  defp validate_spec_keys(spec, kind) do
    common = [:kind, :name, :deps, :provenance]

    kind_keys = %{
      step: [:action, :input],
      choice: [:options, :fallback],
      map: [:collection, :action, :input, :on_error],
      reduce: [:collection, :initial, :action, :input],
      iterate: [:action, :input, :state, :completion, :max_iterations]
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
    {:ok,
     %{
       name: Map.get(spec, :name),
       deps: Map.get(spec, :deps, []),
       provenance: Map.get(spec, :provenance, %{})
     }}
  end

  defp build_node_kind(:step, spec, attrs) do
    Node.new(
      Map.merge(attrs, %{
        action: Map.get(spec, :action),
        input: Map.get(spec, :input, %{})
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
        input: Map.get(spec, :input, %{}),
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
        input: Map.get(spec, :input, %{})
      })
    )
  end

  defp build_node_kind(:iterate, spec, attrs) do
    Iterator.new(
      Map.merge(attrs, %{
        action: Map.get(spec, :action),
        input: Map.get(spec, :input, %{}),
        state: Map.get(spec, :state),
        completion: Map.get(spec, :completion),
        max_iterations: Map.get(spec, :max_iterations)
      })
    )
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
