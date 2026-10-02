defmodule Jido.Flow.Graph do
  @moduledoc false

  alias Jido.Flow.Component

  @doc false
  @spec canonical_components([Component.t()]) :: [Component.t()]
  def canonical_components(components) do
    %{levels: levels, remaining: []} = analyze(components)

    Enum.sort_by(components, fn component ->
      name = Component.name_of(component)
      {Map.fetch!(levels, name), name}
    end)
  end

  @doc false
  @spec analyze([Component.t()]) :: %{
          levels: %{optional(String.t()) => non_neg_integer()},
          remaining: [String.t()]
        }
  def analyze(components) do
    {indegrees, adjacency} =
      components
      |> Enum.reverse()
      |> Enum.reduce({%{}, %{}}, fn component, {indegrees, adjacency} ->
        name = Component.name_of(component)
        dependencies = component |> Component.effective_dependencies() |> MapSet.new()

        adjacency =
          Enum.reduce(dependencies, adjacency, fn dependency, adjacency ->
            Map.update(adjacency, dependency, [name], &[name | &1])
          end)

        {Map.put(indegrees, name, MapSet.size(dependencies)), adjacency}
      end)

    ready =
      Enum.reduce(components, [], fn component, ready ->
        name = Component.name_of(component)

        if Map.fetch!(indegrees, name) == 0 do
          [name | ready]
        else
          ready
        end
      end)
      |> Enum.reverse()

    levels = Map.new(ready, &{&1, 0})

    ready
    |> :queue.from_list()
    |> do_analyze(indegrees, adjacency, levels)
  end

  defp do_analyze(ready, indegrees, adjacency, levels) do
    case :queue.out(ready) do
      {:empty, _ready} ->
        %{levels: levels, remaining: Map.keys(indegrees)}

      {{:value, name}, ready} ->
        level = Map.fetch!(levels, name)
        indegrees = Map.delete(indegrees, name)

        {ready, indegrees, levels} =
          adjacency
          |> Map.get(name, [])
          |> Enum.reduce({ready, indegrees, levels}, fn dependent, {ready, indegrees, levels} ->
            next_indegree = Map.fetch!(indegrees, dependent) - 1
            dependent_level = max(Map.get(levels, dependent, 0), level + 1)
            levels = Map.put(levels, dependent, dependent_level)
            indegrees = Map.put(indegrees, dependent, next_indegree)

            ready =
              if next_indegree == 0 do
                :queue.in(dependent, ready)
              else
                ready
              end

            {ready, indegrees, levels}
          end)

        do_analyze(ready, indegrees, adjacency, levels)
    end
  end
end
