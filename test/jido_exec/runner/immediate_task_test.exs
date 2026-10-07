defmodule Jido.Exec.Runner.ImmediateTaskTest do
  use ExUnit.Case, async: false

  alias Jido.Exec

  defmodule BlockingAction do
    use Jido.Action, name: "exec_immediate_blocking"

    @impl true
    def run(_params, %{observer: observer}) do
      send(observer, {:action_started, self(), Process.group_leader()})

      receive do
        :release -> {:ok, %{released: true}}
      end
    end
  end

  defmodule KillingAction do
    use Jido.Action, name: "exec_immediate_killing"

    @impl true
    def run(_params, _context), do: Process.exit(self(), :kill)
  end

  test "run/4 executes under the application Task Supervisor by default" do
    expected_group_leader = Process.group_leader()
    caller = run_blocking([])

    assert_receive {:action_started, action_pid, ^expected_group_leader}, 1_000
    refute action_pid == elem(caller, 0)
    refute action_pid in elem(Process.info(elem(caller, 0), :links), 1)
    assert action_pid in Task.Supervisor.children(Jido.Exec.TaskSupervisor)

    send(action_pid, :release)
    assert_caller_result(caller, {:ok, %{released: true}})
  end

  test "run/4 preserves the caller group leader" do
    group_leader = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> if Process.alive?(group_leader), do: Process.exit(group_leader, :kill) end)
    caller = run_blocking([], group_leader)

    assert_receive {:action_started, action_pid, ^group_leader}, 1_000
    send(action_pid, :release)
    assert_caller_result(caller, {:ok, %{released: true}})

    send(group_leader, :stop)
  end

  test "run/4 accepts an injected Task Supervisor" do
    supervisor = start_supervised!(Task.Supervisor)
    expected_group_leader = Process.group_leader()
    caller = run_blocking(task_supervisor: supervisor)

    assert_receive {:action_started, action_pid, ^expected_group_leader}, 1_000
    assert action_pid in Task.Supervisor.children(supervisor)
    refute action_pid in Task.Supervisor.children(Jido.Exec.TaskSupervisor)

    send(action_pid, :release)
    assert_caller_result(caller, {:ok, %{released: true}})
  end

  test "an untrappable Action exit does not exit the caller" do
    assert {:error, %Jido.Action.Error.ExecutionFailureError{details: details}} =
             Exec.run(KillingAction)

    assert details.phase == :execution_task
    assert details.reason == :killed
    assert Process.alive?(self())
  end

  defp run_blocking(opts, group_leader \\ nil) do
    owner = self()

    spawn_monitor(fn ->
      if group_leader, do: Process.group_leader(self(), group_leader)
      result = Exec.run(BlockingAction, %{}, %{observer: owner}, opts)
      send(owner, {:caller_result, self(), result})
    end)
  end

  defp assert_caller_result({caller, monitor}, expected) do
    assert_receive {:caller_result, ^caller, ^expected}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}, 1_000
  end
end
