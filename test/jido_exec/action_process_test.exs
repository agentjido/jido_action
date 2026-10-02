defmodule JidoActionTest.Exec.ActionProcessTest do
  use JidoActionTest.Case, async: true

  @moduletag capture_log: true

  alias Jido.Action.Error
  alias Jido.Exec
  alias Jido.Instruction
  alias JidoActionTest.Fixtures.Execution, as: Fixtures
  alias JidoActionTest.Fixtures.Execution.BlockingAction
  alias JidoActionTest.Fixtures.KillingFlow
  alias JidoActionTest.Fixtures.BlockingFlow
  alias JidoActionTest.Fixtures.Actions.KillingAction

  test "direct Action and serial Flow hard kills return structured errors" do
    owner = self()

    paths =
      [
        action: fn -> Exec.run(KillingAction) end,
        instruction: fn -> Exec.run(Instruction.new!(target: KillingAction)) end
      ] ++
        Fixtures.flow_execution_paths(KillingFlow, %{})

    for {_form, run} <- paths do
      {caller, monitor} = spawn_monitor(fn -> send(owner, {:hard_kill_result, run.()}) end)
      assert_receive {:hard_kill_result, {:error, error}}, 1_000
      assert error.details.reason == :killed
      refute Error.retryable?(error)
      assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}, 1_000
    end
  end

  test "timed Action and Flow worker kills become execution boundary errors" do
    for target <- [KillingAction, Instruction.new!(target: KillingAction), KillingFlow] do
      assert {:error, error} = Exec.run(target, %{}, %{}, timeout: 5_000)
      assert error.details.reason == :killed
      refute Error.retryable?(error)
    end
  end

  test "untimed work stops when the Exec caller exits for every executable form" do
    owner = self()

    for {form, {target, input, context}} <-
          Fixtures.blocking_execution_forms(BlockingFlow, owner) do
      {caller, caller_monitor} =
        spawn_monitor(fn ->
          Exec.run(target, input, context)
        end)

      on_exit(fn -> Process.exit(caller, :kill) end)
      assert_receive {:blocking_flow_node_started, worker}, 2_000, to_string(form)
      refute worker == caller
      on_exit(fn -> Process.exit(worker, :kill) end)
      worker_monitor = Process.monitor(worker)
      # Confirm the monitor before caller cleanup can terminate this worker.
      assert {:monitored_by, monitors} = Process.info(worker, :monitored_by)
      assert self() in monitors

      Process.exit(caller, :kill)

      assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}, 1_000
      assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 1_000
    end
  end

  test "finite-timeout work stops when the Exec caller exits" do
    owner = self()

    {caller, caller_monitor} =
      spawn_monitor(fn ->
        Exec.run(BlockingAction, %{value: 1}, %{test_pid: owner}, timeout: 10_000)
      end)

    on_exit(fn -> Process.exit(caller, :kill) end)
    assert_receive {:blocking_flow_node_started, worker}, 1_000
    refute worker == caller
    on_exit(fn -> Process.exit(worker, :kill) end)
    worker_monitor = Process.monitor(worker)
    assert {:monitored_by, monitors} = Process.info(worker, :monitored_by)
    assert self() in monitors

    Process.exit(caller, :kill)

    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}, 1_000
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 1_000
  end

  test "runs concurrent Action scopes under the shared Task Supervisor" do
    owner = self()

    first_caller =
      spawn(fn ->
        result = Exec.run(BlockingAction, %{value: 1}, %{test_pid: owner}, timeout: 10_000)
        send(owner, {:action_result, :first, result})
      end)

    second_caller =
      spawn(fn ->
        result = Exec.run(BlockingAction, %{value: 2}, %{test_pid: owner}, timeout: 10_000)
        send(owner, {:action_result, :second, result})
      end)

    on_exit(fn ->
      Process.exit(first_caller, :kill)
      Process.exit(second_caller, :kill)
    end)

    assert_receive {:blocking_flow_node_started, first_worker}, 1_000
    assert_receive {:blocking_flow_node_started, second_worker}, 1_000
    refute first_worker == second_worker

    supervisor_children = Task.Supervisor.children(Jido.Exec.TaskSupervisor)
    assert scope_controller(first_worker) in supervisor_children
    assert scope_controller(second_worker) in supervisor_children

    send(first_worker, :finish)
    send(second_worker, :finish)

    assert_receive {:action_result, :first, {:ok, %{value: 1}}}, 1_000
    assert_receive {:action_result, :second, {:ok, %{value: 2}}}, 1_000
  end

  test "routes every executable form through one named supervisor" do
    instance = unique_module("JidoInstance")
    task_supervisor = Module.concat(instance, TaskSupervisor)
    start_supervised!({Task.Supervisor, name: task_supervisor})

    owner = self()

    Enum.each(Fixtures.blocking_execution_forms(BlockingFlow, owner), fn {
                                                                           form,
                                                                           {target, input,
                                                                            context}
                                                                         } ->
      caller =
        Task.async(fn ->
          result =
            Exec.run(target, input, context, task_supervisor: task_supervisor, timeout: 10_000)

          send(owner, {:instance_routed_result, form, result})
        end)

      assert_receive {:blocking_flow_node_started, worker}, 1_000
      assert scope_controller(worker) in Task.Supervisor.children(task_supervisor)
      refute worker in Task.Supervisor.children(Jido.Exec.TaskSupervisor)

      send(worker, :finish)
      assert_receive {:instance_routed_result, ^form, {:ok, %{value: _value}}}, 1_000
      Task.await(caller)
    end)
  end

  defp scope_controller(worker) do
    {:dictionary, dictionary} = Process.info(worker, :dictionary)
    [supervisor | _] = dictionary[:"$ancestors"]
    {:dictionary, dictionary} = Process.info(supervisor, :dictionary)
    hd(dictionary[:"$ancestors"])
  end
end
