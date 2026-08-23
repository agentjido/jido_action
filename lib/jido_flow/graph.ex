defmodule Jido.Flow.Graph do
  @moduledoc false

  alias Jido.Flow.Element

  @doc false
  @spec canonical_nodes([Element.t()]) :: [Element.t()]
  def canonical_nodes(nodes) do
    sorted_nodes =
      nodes
      |> Map.new(fn node -> {Element.name(node), node} end)
      |> Map.values()
      |> Enum.sort_by(fn node -> node |> Element.name() |> node_name_sort_key() end)

    %{levels: levels, max_level: max_level, remaining: remaining} = analyze(sorted_nodes)

    blocked = MapSet.new(remaining)

    nodes_by_level =
      sorted_nodes
      |> Enum.reject(&MapSet.member?(blocked, Element.name(&1)))
      |> Enum.group_by(&Map.fetch!(levels, Element.name(&1)))

    ordered_nodes =
      if max_level < 0 do
        []
      else
        Enum.flat_map(0..max_level, fn level ->
          Map.get(nodes_by_level, level, [])
        end)
      end

    blocked_nodes = Enum.filter(sorted_nodes, &MapSet.member?(blocked, Element.name(&1)))

    ordered_nodes ++ blocked_nodes
  end

  @doc false
  @spec analyze([Element.t()]) :: %{
          levels: %{optional(String.t()) => non_neg_integer()},
          max_level: integer(),
          remaining: [String.t()]
        }
  def analyze(nodes) do
    {indegrees, adjacency} =
      nodes
      |> Enum.reverse()
      |> Enum.reduce({%{}, %{}}, fn node, {indegrees, adjacency} ->
        name = Element.name(node)
        dependencies = node |> Element.deps() |> MapSet.new()

        adjacency =
          Enum.reduce(dependencies, adjacency, fn dependency, adjacency ->
            Map.update(adjacency, dependency, [name], &[name | &1])
          end)

        {Map.put(indegrees, name, MapSet.size(dependencies)), adjacency}
      end)

    ready =
      Enum.reduce(nodes, [], fn node, ready ->
        name = Element.name(node)

        if Map.fetch!(indegrees, name) == 0 do
          [name | ready]
        else
          ready
        end
      end)
      |> Enum.reverse()

    levels = Map.new(ready, &{&1, 0})
    max_level = if ready == [], do: -1, else: 0

    ready
    |> :queue.from_list()
    |> do_analyze(indegrees, adjacency, levels, max_level)
  end

  defp node_name_sort_key(name), do: to_string(name)

  defp do_analyze(ready, indegrees, adjacency, levels, max_level) do
    case :queue.out(ready) do
      {:empty, _ready} ->
        %{levels: levels, max_level: max_level, remaining: Map.keys(indegrees)}

      {{:value, name}, ready} ->
        level = Map.fetch!(levels, name)
        indegrees = Map.delete(indegrees, name)

        {ready, indegrees, levels, max_level} =
          adjacency
          |> Map.get(name, [])
          |> Enum.reduce({ready, indegrees, levels, max_level}, fn dependent,
                                                                   {ready, indegrees, levels,
                                                                    max_level} ->
            next_indegree = Map.fetch!(indegrees, dependent) - 1
            dependent_level = max(Map.get(levels, dependent, 0), level + 1)
            levels = Map.put(levels, dependent, dependent_level)
            indegrees = Map.put(indegrees, dependent, next_indegree)

            {ready, max_level} =
              if next_indegree == 0 do
                {:queue.in(dependent, ready), max(max_level, dependent_level)}
              else
                {ready, max_level}
              end

            {ready, indegrees, levels, max_level}
          end)

        do_analyze(ready, indegrees, adjacency, levels, max_level)
    end
  end
end
