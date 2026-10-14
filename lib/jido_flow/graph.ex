defmodule Jido.Flow.Graph do
  @moduledoc false

  alias Jido.Flow.Definition

  @doc false
  @spec canonical_components(Definition.components()) :: [Definition.named_component()]
  def canonical_components(components) when is_map(components) do
    %{levels: levels, remaining: []} = analyze(components)

    components
    |> Map.to_list()
    |> Enum.sort_by(fn {name, _node} -> {Map.fetch!(levels, name), name} end)
  end

  @doc false
  @spec analyze(Definition.components()) :: %{
          levels: %{optional(String.t()) => non_neg_integer()},
          remaining: [String.t()]
        }
  def analyze(components) when is_map(components) do
    graph = dependency_graph(components)
    blocked = blocked_vertices(graph, components)

    levels =
      graph
      |> Multigraph.delete_vertices(blocked)
      |> Multigraph.topsort()
      |> Enum.reduce(%{}, fn name, levels ->
        level = Map.get(levels, name, 0)
        levels = Map.put(levels, name, level)

        graph
        |> Multigraph.out_neighbors(name)
        |> Enum.reduce(levels, fn dependent, levels ->
          Map.update(levels, dependent, level + 1, &max(&1, level + 1))
        end)
      end)

    remaining = blocked |> Enum.filter(&Map.has_key?(components, &1)) |> Enum.sort()
    %{levels: levels, remaining: remaining}
  end

  defp dependency_graph(components) do
    graph =
      Multigraph.new(vertex_identifier: &Function.identity/1)
      |> Multigraph.add_vertices(Map.keys(components))

    Enum.reduce(components, graph, fn {name, node}, graph ->
      node
      |> Definition.effective_dependencies()
      |> Enum.reduce(graph, fn dependency, graph ->
        Multigraph.add_edge(graph, dependency, name)
      end)
    end)
  end

  defp blocked_vertices(graph, components) do
    cycles =
      graph
      |> Multigraph.strong_components()
      |> Enum.flat_map(fn
        [name] -> if name in Multigraph.out_neighbors(graph, name), do: [name], else: []
        names -> names
      end)

    missing = graph |> Multigraph.vertices() |> Enum.reject(&Map.has_key?(components, &1))
    Multigraph.reachable(graph, cycles ++ missing)
  end
end
