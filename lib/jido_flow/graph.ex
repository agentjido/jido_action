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
    {indegrees, adjacency} =
      Enum.reduce(components, {%{}, %{}}, fn {name, node}, {indegrees, adjacency} ->
        dependencies = node |> Definition.effective_dependencies() |> MapSet.new()

        adjacency =
          Enum.reduce(dependencies, adjacency, fn dependency, current ->
            Map.update(current, dependency, [name], &[name | &1])
          end)

        {Map.put(indegrees, name, MapSet.size(dependencies)), adjacency}
      end)

    ready =
      indegrees
      |> Enum.flat_map(fn {name, degree} -> if degree == 0, do: [name], else: [] end)
      |> Enum.sort()

    levels = Map.new(ready, &{&1, 0})

    ready
    |> :queue.from_list()
    |> do_analyze(indegrees, adjacency, levels)
  end

  defp do_analyze(ready, indegrees, adjacency, levels) do
    case :queue.out(ready) do
      {:empty, _ready} ->
        %{levels: levels, remaining: indegrees |> Map.keys() |> Enum.sort()}

      {{:value, name}, ready} ->
        level = Map.fetch!(levels, name)
        indegrees = Map.delete(indegrees, name)

        {ready, indegrees, levels} =
          adjacency
          |> Map.get(name, [])
          |> Enum.sort()
          |> Enum.reduce({ready, indegrees, levels}, fn dependent, {queue, degrees, levels} ->
            next_indegree = Map.fetch!(degrees, dependent) - 1
            dependent_level = max(Map.get(levels, dependent, 0), level + 1)
            levels = Map.put(levels, dependent, dependent_level)
            degrees = Map.put(degrees, dependent, next_indegree)

            queue = if next_indegree == 0, do: :queue.in(dependent, queue), else: queue

            {queue, degrees, levels}
          end)

        do_analyze(ready, indegrees, adjacency, levels)
    end
  end
end
