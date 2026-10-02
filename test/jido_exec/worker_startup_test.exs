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

  for mode <- [:sync, :async] do
    test "#{mode} includes delayed host lookup in its finite deadline" do
      supervisor = start_supervised!(Task.Supervisor)
      observer = self()
      token = make_ref()
      timeout = 50

      {caller, monitor} =
        spawn_monitor(fn ->
          opts = [task_supervisor: {:via, HeldRoute, {observer, token}}, timeout: timeout]

          result =
            case unquote(mode) do
              :sync -> Exec.run(Probe, %{}, %{observer: observer}, opts)
              :async -> Probe |> Exec.run_async(%{}, %{observer: observer}, opts) |> Exec.await()
            end

          send(observer, {token, :result, result})
        end)

      on_exit(fn -> Process.exit(caller, :kill) end)
      assert_receive {^token, :lookup, ^caller}, 1_000
      # The budget started before this lookup. A timer message gives a barrier
      # after that budget expires, without a scheduling-speed assertion.
      Process.send_after(self(), {token, :budget_expired}, timeout)
      assert_receive {^token, :budget_expired}, 1_000
      send(caller, {token, :release, supervisor})
      assert_receive {^token, :lookup, ^caller}, 1_000
      send(caller, {token, :release, supervisor})

      assert_receive {^token, :result,
                      {:error, %Jido.Action.Error.TimeoutError{timeout: ^timeout}}},
                     1_000

      assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}, 1_000
      refute_received :work_started
      refute_received {^token, :lookup, _}
      assert Task.Supervisor.children(supervisor) == []
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
    assert [controller] = Task.Supervisor.children(supervisor)
    refute worker == controller
    send(worker, {token, :release, supervisor})
    assert_receive {^token, :result, {:ok, %{}}}, 1_000
    assert_receive :work_started
    assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}
    assert Task.Supervisor.children(supervisor) == []
  end
end
