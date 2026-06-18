defmodule Jido.Flow.Compiler do
  @moduledoc false

  alias Jido.Flow
  alias Jido.Flow.ComponentFactory
  alias Runic.Workflow

  @doc false
  @spec to_workflow(Flow.t()) :: Workflow.t()
  def to_workflow(%Flow{} = flow) do
    {workflow, entries} = base_workflow(flow)

    entries
    |> validate_reduce_maps!(workflow)
    |> Enum.reduce(workflow, &project_entry/2)
    |> apply_scheduler_policies(flow.policies)
  end

  defp base_workflow(%Flow{name: name, flow: flow_entries}) do
    case flow_entries do
      [%{type: :workflow, workflow: %Workflow{} = workflow, after: nil} | entries] ->
        {workflow, entries}

      entries ->
        {new_workflow(name), entries}
    end
  end

  defp new_workflow(nil), do: Workflow.new()
  defp new_workflow(name), do: Workflow.new(name)

  defp validate_reduce_maps!(entries, %Workflow{} = workflow) do
    initial_maps =
      workflow
      |> Workflow.components()
      |> Enum.reduce(MapSet.new(), fn
        {name, %Runic.Workflow.Map{}}, acc -> MapSet.put(acc, name)
        _entry, acc -> acc
      end)

    entries
    |> Enum.reduce(initial_maps, fn
      %{type: :map, name: name}, maps ->
        MapSet.put(maps, name)

      %{type: :reduce, name: name, map: map_name}, maps when not is_nil(map_name) ->
        if MapSet.member?(maps, map_name) do
          maps
        else
          raise ArgumentError,
                "reduce entry #{inspect(name)} references unknown map #{inspect(map_name)}"
        end

      _entry, maps ->
        maps
    end)

    entries
  end

  defp project_entry(
         %{type: :workflow, workflow: %Workflow{} = child, after: after_dep},
         workflow
       ) do
    add_component_to_workflow(workflow, child, after_dep)
  end

  defp project_entry(entry, workflow) do
    add_component_to_workflow(workflow, ComponentFactory.to_runic!(entry), entry.after)
  end

  defp add_component_to_workflow(%Workflow{} = workflow, component, nil) do
    Workflow.add(workflow, component)
  end

  defp add_component_to_workflow(%Workflow{} = workflow, component, after_dep) do
    Workflow.add(workflow, component, to: after_dep)
  end

  defp apply_scheduler_policies(%Workflow{} = workflow, []), do: workflow

  defp apply_scheduler_policies(%Workflow{} = workflow, policies) do
    existing_policies = Map.get(workflow, :scheduler_policies, [])
    Workflow.set_scheduler_policies(workflow, existing_policies ++ policies)
  end
end
