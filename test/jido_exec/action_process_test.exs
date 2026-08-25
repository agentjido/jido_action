defmodule JidoActionTest.Exec.ActionProcessTest do
  use JidoActionTest.Case, async: true

  @moduletag capture_log: true

  alias Jido.Action.Error
  alias Jido.Action.Error.ExecutionFailureError
  alias Jido.Exec
  alias Jido.Flow
  alias Jido.Flow.{Ref, Step}
  alias Jido.Instruction
  alias JidoActionTest.Fixtures.Execution, as: Fixtures
  alias JidoActionTest.Fixtures.Execution.BlockingAction
  alias JidoActionTest.Fixtures.KillingFlow
  alias JidoActionTest.Fixtures.Actions.KillingAction

  test "contains a killed Action worker outside the caller process" do
    instruction = Instruction.new!(target: KillingAction)

    for executable <- [KillingAction, instruction] do
      assert {:error,
              %ExecutionFailureError{
                message: "action execution process exited",
                details: %{action: KillingAction, reason: :killed}
              } = error} =
               run_in_monitored_caller(fn -> Exec.run(executable) end,
                 assert_mailbox_empty: true
               )

      refute Error.retryable?(error)
    end
  end

  test "contains a killed Action in every Flow execution form" do
    for {form, run} <- Fixtures.flow_execution_paths(KillingFlow, %{}) do
      assert {:error,
              %ExecutionFailureError{
                message: "action execution process exited",
                details: %{action: KillingAction, reason: :killed}
              }} = run.(),
             to_string(form)
    end
  end

  test "terminates the Action worker when the Exec caller exits" do
    owner = self()

    {caller, caller_monitor} =
      spawn_monitor(fn ->
        Exec.run(BlockingAction, %{value: 1}, %{test_pid: owner})
      end)

    assert_receive {:blocking_flow_node_started, worker}, 1_000
    refute worker == caller
    worker_monitor = Process.monitor(worker)

    Process.exit(caller, :kill)

    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}, 1_000
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 1_000
  end

  test "runs concurrent Action workers under the shared Task Supervisor" do
    owner = self()

    first_caller =
      spawn(fn ->
        result = Exec.run(BlockingAction, %{value: 1}, %{test_pid: owner})
        send(owner, {:action_result, :first, result})
      end)

    second_caller =
      spawn(fn ->
        result = Exec.run(BlockingAction, %{value: 2}, %{test_pid: owner})
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
    assert first_worker in supervisor_children
    assert second_worker in supervisor_children

    send(first_worker, :finish)
    send(second_worker, :finish)

    assert_receive {:action_result, :first, {:ok, %{value: 1}}}, 1_000
    assert_receive {:action_result, :second, {:ok, %{value: 2}}}, 1_000
  end

  test "routes Action, Instruction, and Flow workers through one Jido instance" do
    instance = unique_module("JidoInstance")
    task_supervisor = Module.concat(instance, TaskSupervisor)
    start_supervised!({Task.Supervisor, name: task_supervisor})

    flow =
      Flow.new!(
        name: "instance_routed_flow",
        components: [
          Step.new!(
            name: "blocking",
            action: BlockingAction,
            params: %{value: Ref.input(:value)}
          )
        ],
        output: Ref.result("blocking")
      )

    instruction = Instruction.new!(target: BlockingAction, params: %{value: 2})
    owner = self()

    paths = [
      action: fn -> Exec.run(BlockingAction, %{value: 1}, %{test_pid: owner}, jido: instance) end,
      instruction: fn -> Exec.run(instruction, %{}, %{test_pid: owner}, jido: instance) end,
      flow: fn -> Exec.run(flow, %{value: 3}, %{test_pid: owner}, jido: instance) end
    ]

    Enum.each(paths, fn {form, run} ->
      caller =
        Task.async(fn ->
          result = run.()
          send(owner, {:instance_routed_result, form, result})
        end)

      assert_receive {:blocking_flow_node_started, worker}, 1_000
      assert worker in Task.Supervisor.children(task_supervisor)
      refute worker in Task.Supervisor.children(Jido.Exec.TaskSupervisor)

      send(worker, :finish)
      assert_receive {:instance_routed_result, ^form, {:ok, %{value: _value}}}, 1_000
      Task.await(caller)
    end)
  end
end
