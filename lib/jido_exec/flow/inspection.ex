defmodule Jido.Exec.Flow.Inspection do
  @moduledoc false

  alias Jido.Exec.{Execution, Work}
  alias Jido.Flow.Compiler.Payload
  alias Runic.Workflow
  alias Runic.Workflow.{InputBinding, Join, Runnable}

  @doc false
  @spec work(Execution.t(), Runnable.t(), non_neg_integer()) :: Work.t()
  def work(execution, runnable, position) do
    metadata = metadata(runnable.node, execution.workflow, execution.compiled.work_index)
    {role, item_index} = item(metadata.role, runnable.input_fact.value)
    status = if runnable.status == :pending, do: :ready, else: runnable.status

    Work.new(
      Map.merge(metadata, %{role: role, item_index: item_index, status: status}),
      execution.work_ref,
      execution.revision,
      position
    )
  end

  defp metadata(%InputBinding{target_component_hash: target}, _workflow, index) do
    index
    |> Map.fetch!(target)
    |> Map.put(:role, :input_binding)
  end

  defp metadata(%Join{} = join, workflow, index) do
    owners =
      workflow
      |> Workflow.next_steps(join)
      |> Enum.map(&metadata(&1, workflow, index))
      |> Enum.map(&Map.take(&1, [:component_path, :kind]))
      |> Enum.uniq()

    case owners do
      [owner] -> Map.put(owner, :role, :join)
      _ -> %{component_path: nil, kind: :support, role: :join}
    end
  end

  defp metadata(%{hash: hash}, _workflow, index), do: Map.fetch!(index, hash)

  defp item(:map_item, payload) do
    case Payload.unwrap(payload) do
      %{kind: :empty} -> {:map_empty, nil}
      %{kind: :item, index: index} -> {:map_item, index}
    end
  end

  defp item(role, _payload), do: {role, nil}
end
