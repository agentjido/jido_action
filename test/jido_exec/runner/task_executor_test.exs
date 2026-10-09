defmodule Jido.Exec.Runner.TaskExecutorTest do
  use ExUnit.Case, async: false

  alias Jido.Exec
  alias JidoActionTest.Fixtures.Actions.KillingAction

  defmodule BlockingAction do
    use Jido.Action, name: "exec_v2_blocking"

    @impl true
    def run(_params, %{observer: observer}) do
      send(Process.whereis(observer), {:blocking_action_started, self()})

      receive do
        :release -> {:ok, %{released: true}}
      end
    end
  end

  test "managed execution contains an Action process crash" do
    runner = start_runner!()
    test_pid = self()

    execution_id = unique_id()

    assert {:ok, worker} =
             Exec.start(runner, execution_id, KillingAction, %{}, %{},
               hooks: [
                 on_failed: fn _runnable, reason, _state ->
                   send(test_pid, {:managed_failed, reason})
                 end,
                 on_idle: fn _state -> send(test_pid, :managed_idle) end
               ]
             )

    assert_receive :managed_idle, 1_000
    refute_received {:managed_failed, _}

    assert {:ok,
            %{status: :stopped, active_units: 0, causes: [%{kind: :uncertain, reason: :killed}]}} =
             Runic.Runner.admission_status(runner, execution_id)

    assert {:ok, workflow} = Runic.Runner.get_workflow(runner, execution_id)

    assert {:error,
            %Jido.Action.Error.ExecutionFailureError{
              details: %{reason: :killed, phase: :execution_task}
            }} = Exec.result(workflow)

    assert is_pid(worker)
    assert Process.alive?(worker)
  end

  test "stopping managed execution cancels its active Action task" do
    runner = start_runner!()
    execution_id = unique_id()
    observer = :"exec_v2_observer_#{System.unique_integer([:positive])}"
    Process.register(self(), observer)
    on_exit(fn -> if Process.whereis(observer) == self(), do: Process.unregister(observer) end)

    assert {:ok, _worker} =
             Exec.start(runner, execution_id, BlockingAction, %{}, %{observer: observer})

    assert_receive {:blocking_action_started, action_pid}, 1_000
    monitor = Process.monitor(action_pid)

    assert :ok = Runic.Runner.stop(runner, execution_id, persist: false)
    assert_receive {:DOWN, ^monitor, :process, ^action_pid, _reason}, 1_000
  end

  test "managed execution releases finished Action tasks" do
    runner = start_runner!()
    execution_id = unique_id()
    test_pid = self()
    params = %{value: 1, amount: 2}
    hooks = [on_idle: fn _state -> send(test_pid, :managed_idle) end]

    assert {:ok, worker} =
             Exec.start(runner, execution_id, JidoActionTest.Fixtures.Actions.Add, params, %{},
               hooks: hooks
             )

    assert_receive :managed_idle, 1_000

    assert %{executor: Runic.Runner.Executor.Task, executor_state: %{tasks: tasks}} =
             :sys.get_state(worker)

    assert tasks == %{}
  end

  test "worker death stops its active Action task" do
    runner = start_runner!()
    observer = :"exec_v2_orphan_observer_#{System.unique_integer([:positive])}"
    Process.register(self(), observer)
    on_exit(fn -> if Process.whereis(observer) == self(), do: Process.unregister(observer) end)

    assert {:ok, worker} =
             Exec.start(runner, unique_id(), BlockingAction, %{}, %{observer: observer})

    assert_receive {:blocking_action_started, action_pid}, 1_000
    monitor = Process.monitor(action_pid)

    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^action_pid, _reason}, 1_000
  end

  defp start_runner! do
    runner = __MODULE__.Runner
    start_supervised!({Runic.Runner, name: runner})
    runner
  end

  defp unique_id, do: {:exec_v2_task_executor, System.unique_integer([:positive])}
end
