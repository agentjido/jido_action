defmodule Jido.Exec.Recovery do
  @moduledoc """
  Adapter-neutral recovery evidence for execution hosts.

  Capabilities describe the pinned runtime's tested guarantees, not a new retry
  policy. Read them before advertising durable retry support. Runtime retry
  counters and deadlines are not observable through the current native API.
  See [Managed Execution](managed-execution.md#retry-recovery-limits).
  """
  @typedoc "Recovery guarantees established by the native runtime audit."
  @type capabilities :: %{
          retry_budget_persisted?: boolean(),
          retry_deadline_persisted?: boolean(),
          retry_releases_task?: boolean(),
          controlled_retry_clock?: boolean(),
          completed_work_preserved?: boolean(),
          terminal_failure_preserved?: boolean()
        }
  @typedoc "Host status without a guessed retry count or deadline."
  @type status :: %{
          execution: :running | :ready | :stopped | :quiescent,
          retry_state: :unavailable,
          persistence: map()
        }

  @doc "Reports the pinned runtime's tested recovery capabilities."
  @spec capabilities() :: capabilities()
  def capabilities do
    %{
      retry_budget_persisted?: false,
      retry_deadline_persisted?: false,
      retry_releases_task?: false,
      controlled_retry_clock?: false,
      completed_work_preserved?: true,
      terminal_failure_preserved?: true
    }
  end

  @doc "Reads current execution and Store acknowledgement without inferring retry state."
  @spec status(module(), term()) :: {:ok, status()} | {:error, term()}
  def status(runner, execution_id) do
    with {:ok, admission} <- Runic.Runner.admission_status(runner, execution_id),
         {:ok, workflow} <- Runic.Runner.get_workflow(runner, execution_id),
         {:ok, persistence} <- Runic.Runner.persistence_status(runner, execution_id) do
      execution =
        cond do
          admission.active_units > 0 -> :running
          admission.status == :stopped -> :stopped
          Runic.Workflow.is_runnable?(workflow) -> :ready
          true -> :quiescent
        end

      {:ok, %{execution: execution, retry_state: :unavailable, persistence: persistence}}
    end
  end
end
