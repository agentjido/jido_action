defmodule Jido.Exec.ExecutionGuard do
  @moduledoc false

  alias Jido.Action.Error
  alias Jido.Exec.Execution

  @type t :: :atomics.atomics_ref()
  @opaque operation :: {pid(), reference(), reference(), pos_integer()}

  @revision_index 1
  @state_index 2
  @available 0
  @indeterminate 1

  @doc false
  @spec new() :: t()
  def new, do: :atomics.new(2, signed: false)

  @doc false
  @spec claim(Execution.t()) :: {:ok, operation()} | {:error, Exception.t()}
  def claim(%Execution{guard: guard, revision: revision} = execution) do
    owner = self()
    operation_ref = make_ref()
    token = :erlang.unique_integer([:monotonic, :positive]) + 1

    {helper, helper_monitor} =
      spawn_monitor(fn -> claim_operation(owner, operation_ref, guard, revision, token) end)

    receive do
      {^operation_ref, ^helper, :claim, :ok} ->
        {:ok, {helper, operation_ref, helper_monitor, token}}

      {^operation_ref, ^helper, :claim, {:error, current_revision, state}} ->
        Process.demonitor(helper_monitor, [:flush])
        stale_error(execution, current_revision, state)

      {:DOWN, ^helper_monitor, :process, ^helper, reason} ->
        mark_indeterminate(guard, token)
        raise "flow execution guard helper exited during claim: #{inspect(reason)}"
    end
  end

  @doc false
  @spec advance(operation(), Execution.t(), Execution.t()) :: :ok
  def advance(
        operation,
        %Execution{guard: guard, revision: prior_revision},
        %Execution{guard: guard, revision: next_revision}
      )
      when next_revision > prior_revision do
    finish_operation(operation, {:advance, next_revision}, guard)
  end

  @doc false
  @spec release(operation(), Execution.t()) :: :ok
  def release(operation, %Execution{guard: guard}) do
    finish_operation(operation, :release, guard)
  end

  @doc false
  @spec interrupt(operation(), Execution.t()) :: :ok
  def interrupt(operation, %Execution{guard: guard}) do
    finish_operation(operation, :interrupt, guard)
  end

  defp claim_operation(owner, operation_ref, guard, revision, token) do
    owner_monitor = Process.monitor(owner)

    case claim_state(guard, revision, token) do
      :ok ->
        send(owner, {operation_ref, self(), :claim, :ok})
        await_operation(owner, owner_monitor, operation_ref, guard, token)

      {:error, _current_revision, _state} = error ->
        Process.demonitor(owner_monitor, [:flush])
        send(owner, {operation_ref, self(), :claim, error})
    end
  end

  defp claim_state(guard, revision, token) do
    case :atomics.compare_exchange(guard, @state_index, @available, token) do
      :ok ->
        current_revision = :atomics.get(guard, @revision_index)

        if current_revision == revision do
          :ok
        else
          :atomics.compare_exchange(guard, @state_index, token, @available)
          {:error, current_revision, @available}
        end

      state ->
        {:error, :atomics.get(guard, @revision_index), state}
    end
  end

  defp await_operation(owner, owner_monitor, operation_ref, guard, token) do
    receive do
      {^operation_ref, ^owner, {:advance, next_revision}} ->
        finish_claimed_operation(owner, owner_monitor, operation_ref, fn ->
          advance_state(guard, token, next_revision)
        end)

      {^operation_ref, ^owner, :release} ->
        finish_claimed_operation(owner, owner_monitor, operation_ref, fn ->
          :atomics.compare_exchange(guard, @state_index, token, @available)
        end)

      {^operation_ref, ^owner, :interrupt} ->
        finish_claimed_operation(owner, owner_monitor, operation_ref, fn ->
          :atomics.compare_exchange(guard, @state_index, token, @indeterminate)
        end)

      {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
        mark_indeterminate(guard, token)
    end
  end

  defp advance_state(guard, token, next_revision) do
    case :atomics.get(guard, @state_index) do
      ^token ->
        :atomics.put(guard, @revision_index, next_revision)
        :atomics.compare_exchange(guard, @state_index, token, @available)

      actual ->
        actual
    end
  end

  defp finish_claimed_operation(owner, owner_monitor, operation_ref, transition) do
    result = transition.()
    Process.demonitor(owner_monitor, [:flush])
    send(owner, {operation_ref, self(), :finish, result})
  end

  defp finish_operation(
         {helper, operation_ref, helper_monitor, token},
         command,
         guard
       ) do
    send(helper, {operation_ref, self(), command})

    receive do
      {^operation_ref, ^helper, :finish, :ok} ->
        Process.demonitor(helper_monitor, [:flush])
        :ok

      {^operation_ref, ^helper, :finish, actual} ->
        Process.demonitor(helper_monitor, [:flush])
        raise_guard_changed(actual)

      {:DOWN, ^helper_monitor, :process, ^helper, reason} ->
        case :atomics.get(guard, @state_index) do
          ^token ->
            mark_indeterminate(guard, token)
            raise "flow execution guard helper exited during finish: #{inspect(reason)}"

          _completed_or_newer_state ->
            :ok
        end
    end
  end

  defp mark_indeterminate(guard, token) do
    case :atomics.compare_exchange(guard, @state_index, token, @indeterminate) do
      :ok -> :ok
      @indeterminate -> :ok
      _other_state -> :ok
    end
  end

  defp stale_error(execution, current_revision, state) do
    {:error,
     Error.validation_error("stale flow execution", %{
       flow: execution.flow_name,
       execution_id: execution.id,
       reason: stale_reason(state, current_revision, execution.revision),
       revision: execution.revision,
       current_revision: current_revision
     })}
  end

  defp raise_guard_changed(actual) do
    raise "flow execution guard changed during an active operation: #{inspect(actual)}"
  end

  defp stale_reason(state, current_revision, revision) do
    cond do
      state == @indeterminate -> :indeterminate
      state > @indeterminate and current_revision == revision -> :operation_in_progress
      true -> :stale_revision
    end
  end
end
