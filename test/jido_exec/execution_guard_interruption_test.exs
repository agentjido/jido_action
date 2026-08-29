defmodule JidoActionTest.Exec.ExecutionGuardInterruptionTest do
  use ExUnit.Case, async: false

  alias Jido.Flow.Error.InvalidExecutionError
  alias Jido.Exec
  alias Jido.Exec.ExecutionGuard
  alias Jido.Flow
  alias Jido.Flow.{Ref, Step}
  alias JidoActionTest.Fixtures.Execution, as: ExecFixtures
  alias JidoActionTest.Fixtures.Actions.RecorderAction

  @node_stop [:jido, :flow, :node, :stop]

  test "marks a mutation indeterminate when its owner exits during Action work" do
    flow =
      Flow.new!(
        name: "interrupted_action_work",
        components: [Step.new!(name: "block", action: ExecFixtures.BlockingAction)],
        output: Ref.result("block")
      )

    assert {:ok, execution} = Exec.start(flow, %{}, %{test_pid: self()})
    {caller, caller_monitor} = spawn_monitor(fn -> Exec.step(execution) end)

    assert_receive {:blocking_flow_node_started, worker}, 1_000
    worker_monitor = Process.monitor(worker)
    Process.exit(caller, :kill)

    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}, 1_000
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 1_000
    assert_guard_indeterminate(execution)

    assert {:error, %InvalidExecutionError{details: %{reason: :indeterminate}}} =
             Exec.step(execution)
  end

  test "does not replay an Action completed before its mutation owner exits" do
    flow = recorder_flow("interrupted_after_action_effect")
    assert {:ok, execution} = Exec.start(flow, %{}, %{test_pid: self()})
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(handler, @node_stop, &__MODULE__.kill_owner_after_node_stop/4, self())

    on_exit(fn -> :telemetry.detach(handler) end)
    {caller, caller_monitor} = spawn_monitor(fn -> Exec.step(execution) end)

    assert_receive {RecorderAction, %{value: :once}}, 1_000
    assert_receive {:node_stopped_before_guard_advance, ^caller}, 1_000
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}, 1_000
    assert_guard_indeterminate(execution)

    assert {:error, %InvalidExecutionError{details: %{reason: :indeterminate}}} =
             Exec.step(execution)

    refute_received {RecorderAction, %{value: :once}}
  end

  test "keeps an advance completed before its owner exits" do
    assert {:ok, execution} = Exec.start(recorder_flow("guard_advance_before_down"))
    next_execution = %{execution | revision: 1}

    {owner, owner_monitor} =
      spawn_monitor(fn ->
        {:ok, operation} = ExecutionGuard.claim(execution)
        :ok = ExecutionGuard.advance(operation, execution, next_execution)
      end)

    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}, 1_000

    assert {:error,
            %InvalidExecutionError{
              details: %{reason: :stale_revision, revision: 0, current_revision: 1}
            }} = Exec.step(execution)
  end

  test "does not let a failed claimant change the active guard" do
    assert {:ok, execution} = Exec.start(recorder_flow("guard_failed_claimant"))
    test_pid = self()

    {owner, owner_monitor} =
      spawn_monitor(fn ->
        {:ok, {helper, _operation_ref, _helper_monitor, _token}} =
          ExecutionGuard.claim(execution)

        send(test_pid, {:guard_claimed, self(), helper})
        receive do: (:release -> :ok)
      end)

    assert_receive {:guard_claimed, ^owner, helper}, 1_000
    helper_monitor = Process.monitor(helper)

    {claimant, claimant_monitor} =
      spawn_monitor(fn -> send(test_pid, {:failed_claim, ExecutionGuard.claim(execution)}) end)

    assert_receive {:failed_claim,
                    {:error, %InvalidExecutionError{details: %{reason: :operation_in_progress}}}},
                   1_000

    assert_receive {:DOWN, ^claimant_monitor, :process, ^claimant, :normal}, 1_000

    assert {:error, %InvalidExecutionError{details: %{reason: :operation_in_progress}}} =
             Exec.step(execution)

    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :killed}, 1_000
    assert_receive {:DOWN, ^helper_monitor, :process, ^helper, :normal}, 1_000

    assert {:error, %InvalidExecutionError{details: %{reason: :indeterminate}}} =
             Exec.step(execution)
  end

  test "marks the guard indeterminate when a mutation error escapes" do
    assert {:ok, execution} = Exec.start(recorder_flow("guard_escaped_mutation_error"))
    invalid_compiled = %{execution.compiled | component_index: nil}
    invalid_execution = %{execution | compiled: invalid_compiled}

    assert_raise Protocol.UndefinedError, fn -> Exec.step(invalid_execution) end

    assert {:error, %InvalidExecutionError{details: %{reason: :indeterminate}}} =
             Exec.step(execution)
  end

  test "marks the guard indeterminate when its helper exits" do
    assert {:ok, execution} = Exec.start(recorder_flow("guard_helper_exit"))

    assert {:ok, {helper, _operation_ref, _helper_monitor, _token} = operation} =
             ExecutionGuard.claim(execution)

    Process.exit(helper, :kill)

    assert_raise RuntimeError, ~r/guard helper exited during finish/, fn ->
      ExecutionGuard.interrupt(operation, execution)
    end

    assert {:error, %InvalidExecutionError{details: %{reason: :indeterminate}}} =
             Exec.step(execution)
  end

  def kill_owner_after_node_stop(
        @node_stop,
        _measurements,
        %{flow: "interrupted_after_action_effect"},
        test_pid
      ) do
    send(test_pid, {:node_stopped_before_guard_advance, self()})
    Process.exit(self(), :kill)
  end

  defp assert_guard_indeterminate(%{guard: guard}) do
    assert await_guard_state(guard, 10_000) == :indeterminate
  end

  defp await_guard_state(_guard, 0), do: :not_indeterminate

  defp await_guard_state(guard, attempts) do
    case :atomics.get(guard, 2) do
      1 -> :indeterminate
      _state -> await_guard_state(guard, attempts - 1)
    end
  end

  defp recorder_flow(name) do
    Flow.new!(
      name: name,
      components: [Step.new!(name: "record", action: RecorderAction, params: %{value: :once})],
      output: Ref.result("record")
    )
  end
end
