defmodule Jido.Flow.Inspection do
  @moduledoc false

  alias Jido.Flow.Element
  alias Jido.Flow.Graph
  alias Jido.Flow.Identity
  alias Jido.Flow.SemanticMap

  @doc false
  @spec dependencies(map()) :: {:ok, %{String.t() => [String.t()]}}
  def dependencies(flow) do
    {:ok, flow.nodes |> Graph.canonical_nodes() |> dependency_map()}
  end

  @doc false
  @spec explain(map()) :: {:ok, map()}
  def explain(flow) do
    nodes = Graph.canonical_nodes(flow.nodes)
    semantic_map = SemanticMap.build(flow, nodes, [])
    dependencies = dependency_map(nodes)

    {:ok,
     %{
       version: 1,
       kind: :flow,
       name: flow.name,
       description: flow.description,
       schema: flow.schema,
       output_schema: flow.output_schema,
       nodes: semantic_map.nodes,
       dependencies: dependencies,
       edges: edges(nodes),
       return: semantic_map.return,
       identity: Identity.identity(semantic_map)
     }}
  end

  @doc false
  @spec semantic_identity(map()) :: {:ok, map()}
  def semantic_identity(flow) do
    {:ok, Identity.for_flow(flow)}
  end

  defp dependency_map(nodes) do
    Map.new(nodes, fn node ->
      {Element.name(node), Element.deps(node) |> Enum.sort()}
    end)
  end

  defp edges(nodes) do
    nodes
    |> Enum.flat_map(fn node ->
      Enum.map(Element.deps(node), fn predecessor ->
        %{from: predecessor, to: Element.name(node)}
      end)
    end)
    |> Enum.sort_by(&{&1.from, &1.to})
  end
end
