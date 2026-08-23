defmodule Jido.Flow.Inspection do
  @moduledoc false

  alias Jido.Flow.Element
  alias Jido.Flow.Graph
  alias Jido.Flow.Node

  @doc false
  @spec dependencies(map(), function()) :: {:ok, %{String.t() => [String.t()]}}
  def dependencies(flow, identity_fun) do
    projection = projection(flow, identity_fun)
    {:ok, projection.dependencies}
  end

  @doc false
  @spec explain(map(), function()) :: {:ok, map()}
  def explain(flow, identity_fun) do
    projection = projection(flow, identity_fun)

    {:ok,
     %{
       version: 1,
       kind: :flow,
       name: projection.flow.name,
       description: projection.flow.description,
       schema: projection.flow.schema,
       output_schema: projection.flow.output_schema,
       nodes: projection.nodes,
       dependencies: projection.dependencies,
       edges: projection.edges,
       return: Node.expression_to_map(projection.flow.return),
       identity: projection.identity
     }}
  end

  @doc false
  @spec semantic_identity(map(), function()) :: {:ok, map()}
  def semantic_identity(flow, identity_fun) do
    projection = projection(flow, identity_fun)
    {:ok, projection.identity}
  end

  defp projection(flow, identity_fun) do
    nodes = Graph.canonical_nodes(flow.nodes)

    dependencies =
      Map.new(nodes, fn node ->
        {Element.name(node), Element.deps(node) |> Enum.sort()}
      end)

    edges =
      nodes
      |> Enum.flat_map(fn node ->
        Enum.map(Element.deps(node), fn predecessor ->
          %{from: predecessor, to: Element.name(node)}
        end)
      end)
      |> Enum.sort_by(&{&1.from, &1.to})

    %{
      flow: flow,
      nodes: Enum.map(nodes, &Element.to_map/1),
      dependencies: dependencies,
      edges: edges,
      identity: identity_fun.(flow, nodes)
    }
  end
end
