defmodule JidoActionTest.Exec.WorkerStartupTest do
  use ExUnit.Case, async: false
  alias Jido.Exec

  defmodule Probe do
    use Jido.Action, name: "startup_probe"

    def run(_, %{observer: observer}) do
      send(observer, :work_started)
      {:ok, %{}}
    end
  end

  defmodule HeldRoute do
    def whereis_name({observer, token}) do
      send(observer, {token, :lookup, self()})
      receive do: ({^token, :release, pid} -> pid)
    end
  end

  test "supervisor lookup runs in the caller without a startup helper" do
    supervisor = start_supervised!(Task.Supervisor)
    observer = self()
    token = make_ref()

    {caller, monitor} =
      spawn_monitor(fn ->
        result =
          Exec.run(Probe, %{}, %{observer: observer},
            task_supervisor: {:via, HeldRoute, {observer, token}},
            timeout: 5_000
          )

        send(observer, {token, :result, result})
      end)

    on_exit(fn -> Process.exit(caller, :kill) end)
    assert_receive {^token, :lookup, ^caller}, 1_000
    refute_received :work_started
    send(caller, {token, :release, supervisor})
    # The route remains intact and is resolved again at task start.
    assert_receive {^token, :lookup, ^caller}, 1_000
    send(caller, {token, :release, supervisor})
    assert_receive {^token, :lookup, worker}, 1_000
    assert [worker] == Task.Supervisor.children(supervisor)
    send(worker, {token, :release, supervisor})
    assert_receive {^token, :result, {:ok, %{}}}, 1_000
    assert_receive :work_started
    assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}
    assert Task.Supervisor.children(supervisor) == []
  end
end
