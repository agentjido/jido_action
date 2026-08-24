defmodule Jido.Exec.ExecutionGuardInterruptionTest do
  use JidoTest.ActionCase, async: false

  alias Jido.Action.Error.InvalidInputError
  alias Jido.Exec
  alias Jido.Exec.ExecutionGuard
  alias Jido.Flow
  alias Jido.Flow.{Node, Ref}
  alias JidoTest.ExecutionFixtures
  alias JidoTest.TestActions.RecorderAction

  @node_stop [:jido, :flow, :node, :stop]

  test "marks a mutation indeterminate when its owner exits during Action work" do
    flow =
      Flow.new!(
        name: "interrupted_action_work",
        nodes: [
          Node.new!(
            name: "block",
            action: ExecutionFixtures.BlockingAction,
            input: %{value: Ref.value(:once)}
          )
        ],
        return: Ref.result("block")
      )

    assert {:ok, execution} = Exec.start(flow, %{}, %{test_pid: self()})
    {caller, caller_monitor} = spawn_monitor(fn -> Exec.step(execution) end)

    assert_receive {:blocking_flow_node_started, worker}, 1_000
    worker_monitor = Process.monitor(worker)

    Process.exit(caller, :kill)

    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}, 1_000
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 1_000

    assert_indeterminate(fn -> Exec.step(execution) end, 50)
    refute_receive {:blocking_flow_node_started, _worker}, 50
  end

  test "does not replay an Action that completed before its mutation owner exited" do
    flow =
      Flow.new!(
        name: "interrupted_after_action_effect",
        nodes: [
          Node.new!(
            name: "record",
            action: RecorderAction,
            input: %{value: Ref.value(:once)}
          )
        ],
        return: Ref.result("record")
      )

    assert {:ok, execution} = Exec.start(flow, %{}, %{test_pid: self()})

    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        @node_stop,
        &__MODULE__.kill_owner_after_node_stop/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    {caller, caller_monitor} = spawn_monitor(fn -> Exec.step(execution) end)

    assert_receive {RecorderAction, %{value: :once}}, 1_000
    assert_receive {:node_stopped_before_guard_advance, ^caller}, 1_000
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}, 1_000

    assert_indeterminate(fn -> Exec.step(execution) end, 50)
    refute_receive {RecorderAction, %{value: :once}}, 50
  end

  test "keeps an advance that the owner completed before it exited" do
    assert {:ok, execution} = Exec.start(recorder_flow("guard_advance_before_down"))
    next_execution = %{execution | revision: 1}

    {owner, owner_monitor} =
      spawn_monitor(fn ->
        {:ok, operation} = ExecutionGuard.claim(execution)
        :ok = ExecutionGuard.advance(operation, execution, next_execution)
      end)

    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}, 1_000

    assert {:error,
            %InvalidInputError{
              details: %{reason: :stale_revision, revision: 0, current_revision: 1}
            }} = Exec.step(execution)
  end

  test "keeps a released revision available after the owner exits" do
    assert {:ok, execution} = Exec.start(recorder_flow("guard_release_before_down"))

    {owner, owner_monitor} =
      spawn_monitor(fn ->
        {:ok, operation} = ExecutionGuard.claim(execution)
        :ok = ExecutionGuard.release(operation, execution)
      end)

    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}, 1_000
    assert {:ok, _node_result, completed} = Exec.step(execution)
    assert completed.revision == 1
  end

  test "does not let a failed claimant change the active owner's guard" do
    assert {:ok, execution} = Exec.start(recorder_flow("guard_failed_claimant"))
    test_pid = self()

    {owner, owner_monitor} =
      spawn_monitor(fn ->
        {:ok, _operation} = ExecutionGuard.claim(execution)
        send(test_pid, {:guard_claimed, self()})
        Process.sleep(:infinity)
      end)

    assert_receive {:guard_claimed, ^owner}, 1_000

    {claimant, claimant_monitor} =
      spawn_monitor(fn ->
        send(test_pid, {:failed_claim, ExecutionGuard.claim(execution)})
      end)

    assert_receive {:failed_claim,
                    {:error, %InvalidInputError{details: %{reason: :operation_in_progress}}}},
                   1_000

    assert_receive {:DOWN, ^claimant_monitor, :process, ^claimant, :normal}, 1_000

    assert {:error, %InvalidInputError{details: %{reason: :operation_in_progress}}} =
             Exec.step(execution)

    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :killed}, 1_000
    assert_indeterminate(fn -> Exec.step(execution) end, 50)
  end

  test "marks the guard indeterminate when a mutation error escapes to a live owner" do
    assert {:ok, execution} = Exec.start(recorder_flow("guard_escaped_mutation_error"))
    invalid_execution = %{execution | options: [async: false]}

    assert_raise KeyError, fn -> Exec.step(invalid_execution) end
    assert_indeterminate(fn -> Exec.step(execution) end, 50)
  end

  test "marks the guard indeterminate when its operation helper exits" do
    assert {:ok, execution} = Exec.start(recorder_flow("guard_helper_exit"))

    assert {:ok, {helper, _operation_ref, _helper_monitor, _token} = operation} =
             ExecutionGuard.claim(execution)

    Process.exit(helper, :kill)

    assert_raise RuntimeError, ~r/guard helper exited during finish/, fn ->
      ExecutionGuard.release(operation, execution)
    end

    assert_indeterminate(fn -> Exec.step(execution) end, 50)
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

  defp assert_indeterminate(fun, attempts) do
    case fun.() do
      {:error,
       %InvalidInputError{
         message: "stale flow execution",
         details: %{reason: :indeterminate}
       }} ->
        :ok

      {:error, %InvalidInputError{details: %{reason: :operation_in_progress}}}
      when attempts > 0 ->
        Process.sleep(10)
        assert_indeterminate(fun, attempts - 1)

      other ->
        flunk("expected an indeterminate flow execution, got: #{inspect(other)}")
    end
  end

  defp recorder_flow(name) do
    Flow.new!(
      name: name,
      nodes: [
        Node.new!(
          name: "record",
          action: RecorderAction,
          input: %{value: Ref.value(:once)}
        )
      ],
      return: Ref.result("record")
    )
  end
end
