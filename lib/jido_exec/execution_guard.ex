defmodule Jido.Exec.ExecutionGuard do
  @moduledoc false

  alias Jido.Action.Error
  alias Jido.Exec.Execution

  @type t :: :atomics.atomics_ref()

  @doc false
  @spec new() :: t()
  def new, do: :atomics.new(1, signed: false)

  @doc false
  @spec claim(Execution.t()) :: :ok | {:error, Exception.t()}
  def claim(%Execution{guard: guard, revision: revision} = execution) do
    expected = available_state(revision)

    case :atomics.compare_exchange(guard, 1, expected, busy_state(revision)) do
      :ok ->
        :ok

      actual ->
        {:error,
         Error.validation_error("stale flow execution", %{
           flow: execution.flow_name,
           execution_id: execution.id,
           reason: stale_reason(actual, revision),
           revision: revision,
           current_revision: state_revision(actual)
         })}
    end
  end

  @doc false
  @spec advance(Execution.t(), Execution.t()) :: :ok
  def advance(
        %Execution{guard: guard, revision: prior_revision},
        %Execution{guard: guard, revision: next_revision}
      )
      when next_revision > prior_revision do
    case :atomics.compare_exchange(
           guard,
           1,
           busy_state(prior_revision),
           available_state(next_revision)
         ) do
      :ok -> :ok
      _actual -> raise "flow execution guard changed during an active operation"
    end
  end

  @doc false
  @spec release(Execution.t()) :: :ok
  def release(%Execution{guard: guard, revision: revision}) do
    case :atomics.compare_exchange(
           guard,
           1,
           busy_state(revision),
           available_state(revision)
         ) do
      :ok -> :ok
      _actual -> raise "flow execution guard changed during an active operation"
    end
  end

  defp available_state(revision), do: revision * 2
  defp busy_state(revision), do: available_state(revision) + 1
  defp state_revision(state), do: div(state, 2)

  defp stale_reason(actual, revision) do
    if actual == busy_state(revision),
      do: :operation_in_progress,
      else: :stale_revision
  end
end
