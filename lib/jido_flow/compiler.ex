defmodule Jido.Flow.Compiler do
  @moduledoc false

  alias Jido.Flow
  alias Jido.Flow.ComponentFactory
  alias Runic.Workflow

  @doc false
  @spec to_workflow(Flow.t()) :: Workflow.t()
  def to_workflow(%Flow{} = flow) do
    {workflow, entries} = base_workflow(flow)
    entries = entries |> expand_entries() |> lower_over_entries() |> wire_sources()

    entries
    |> validate_project_sources!(workflow)
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

  defp validate_project_sources!(entries, %Workflow{} = workflow) do
    initial_names =
      workflow
      |> Workflow.components()
      |> Map.keys()
      |> MapSet.new()

    Enum.reduce(entries, initial_names, fn
      %{type: :project, name: name, from: from} = entry, known_names ->
        unless MapSet.member?(known_names, from) do
          raise ArgumentError,
                "project entry #{inspect(name)} references unknown source #{inspect(from)}"
        end

        add_known_entry_names(known_names, entry)

      entry, known_names ->
        add_known_entry_names(known_names, entry)
    end)

    entries
  end

  defp add_known_entry_names(known_names, %{
         type: :workflow,
         name: name,
         workflow: %Workflow{} = workflow
       }) do
    workflow
    |> Workflow.components()
    |> Map.keys()
    |> Enum.reduce(MapSet.put(known_names, name), &MapSet.put(&2, &1))
  end

  defp add_known_entry_names(known_names, %{name: name}), do: MapSet.put(known_names, name)

  defp expand_entries(entries) do
    Enum.flat_map(entries, &expand_entry/1)
  end

  defp expand_entry(%{type: :chain, flow: flow, after: after_dep}) do
    flow
    |> expand_entries()
    |> wire_chain(after_dep)
  end

  defp expand_entry(%{type: :fanout, from: from, flow: flow}) do
    flow
    |> expand_entries()
    |> Enum.map(&put_default_after(&1, from))
  end

  defp expand_entry(entry), do: [entry]

  defp lower_over_entries(entries) do
    Enum.flat_map(entries, &lower_over_entry/1)
  end

  defp lower_over_entry(%{type: type, over: nil} = entry)
       when type in [:map, :reduce, :accumulate],
       do: [Map.delete(entry, :over)]

  defp lower_over_entry(%{type: type, over: over} = entry)
       when type in [:map, :reduce, :accumulate] do
    case over do
      name when is_atom(name) and not is_nil(name) ->
        [
          entry
          |> Map.delete(:over)
          |> Map.put(:source, {:result, name})
          |> put_default_after(name)
        ]

      {name, opts} when is_atom(name) and not is_nil(name) and is_list(opts) ->
        from = Keyword.fetch!(opts, :from)
        path = Keyword.fetch!(opts, :path)

        [
          %{
            type: :project,
            name: name,
            from: from,
            path: path,
            mode: :value,
            after: from
          },
          entry
          |> Map.delete(:over)
          |> Map.put(:source, {:result, name})
          |> put_default_after(name)
        ]
    end
  end

  defp lower_over_entry(entry), do: [entry]

  defp wire_chain(entries, initial_after) do
    {_last_name, wired} =
      Enum.map_reduce(entries, initial_after, fn entry, previous_name ->
        entry = put_default_after(entry, previous_name)
        next_name = Map.get(entry, :name) || previous_name
        {entry, next_name}
      end)

    wired
  end

  defp put_default_after(entry, nil), do: entry

  defp put_default_after(%{after: nil} = entry, dependency) do
    if source_dependency(Map.get(entry, :source)) do
      entry
    else
      Map.put(entry, :after, dependency)
    end
  end

  defp put_default_after(entry, _dependency), do: entry

  defp wire_sources(entries), do: Enum.flat_map(entries, &wire_entry_source/1)

  defp wire_entry_source(%{type: :collect, after: nil, arguments: arguments} = entry) do
    dependencies =
      arguments
      |> Map.values()
      |> Enum.flat_map(&source_dependencies/1)
      |> Enum.uniq()

    [Map.put(entry, :after, normalize_dependencies(dependencies))]
  end

  defp wire_entry_source(%{source: source} = entry) do
    case source do
      {:result, from} ->
        [entry |> Map.put(:after, entry.after || from) |> maybe_set_reduce_map(from)]

      {:result, from, path} ->
        project_name = source_project_name!(entry.name)

        [
          %{
            type: :project,
            name: project_name,
            from: from,
            path: path,
            mode: :value,
            after: from
          },
          entry
          |> Map.put(:source, {:result, project_name})
          |> Map.put(:after, entry.after || project_name)
          |> maybe_set_reduce_map(project_name)
        ]

      _source ->
        [entry]
    end
  end

  defp wire_entry_source(entry), do: [entry]

  defp maybe_set_reduce_map(%{type: :reduce, map: nil} = entry, map_name),
    do: Map.put(entry, :map, map_name)

  defp maybe_set_reduce_map(entry, _map_name), do: entry

  defp source_dependencies({:result, from}), do: [from]
  defp source_dependencies({:result, from, _path}), do: [from]
  defp source_dependencies(_source), do: []

  defp source_dependency(source) do
    case source_dependencies(source) do
      [dependency | _rest] -> dependency
      [] -> nil
    end
  end

  defp normalize_dependencies([]), do: nil
  defp normalize_dependencies([dependency]), do: dependency
  defp normalize_dependencies(dependencies), do: dependencies

  defp source_project_name!(name) when is_atom(name) do
    generated_name = Atom.to_string(name) <> "_source"

    String.to_existing_atom(generated_name)
  rescue
    ArgumentError ->
      raise ArgumentError,
            "source path for #{inspect(name)} requires an existing generated project atom #{inspect(Atom.to_string(name) <> "_source")}"
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
