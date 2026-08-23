defmodule Jido.Flow.SemanticMap do
  @moduledoc false

  alias Jido.Flow
  alias Jido.Flow.Element
  alias Jido.Flow.Expression
  alias Jido.Flow.Graph

  @semantic_version 1

  @doc false
  @spec build(Flow.t(), keyword()) :: map()
  def build(%Flow{} = flow, opts \\ []) do
    build(flow, Graph.canonical_nodes(flow.nodes), opts)
  end

  @doc false
  @spec build(Flow.t(), [Element.t()], keyword()) :: map()
  def build(%Flow{} = flow, ordered_nodes, opts) when is_list(ordered_nodes) do
    base = %{
      type: :flow,
      version: @semantic_version,
      name: flow.name,
      description: flow.description,
      schema: flow.schema,
      output_schema: flow.output_schema,
      nodes: Enum.map(ordered_nodes, &Element.to_map(&1, opts)),
      return: Expression.to_map(flow.return)
    }

    if Keyword.get(opts, :provenance, false) do
      Map.put(base, :provenance, flow.provenance)
    else
      base
    end
  end
end
