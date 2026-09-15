defmodule JidoActionTest.Exec.ProcessCleanupTest do
  use ExUnit.Case, async: true

  import JidoActionTest.ProcessCleanup

  defmodule ChildTable do
    use GenServer

    def start_link(state), do: GenServer.start_link(__MODULE__, state)
    def init(state), do: {:ok, state}

    def handle_call(:which_children, _from, [children | rest]) do
      rows = Enum.map(children, &{:undefined, &1, :worker, [Task]})
      {:reply, rows, if(rest == [], do: [children], else: rest)}
    end
  end

  test "accepts an empty supervisor" do
    supervisor = start_supervised!(Task.Supervisor)
    assert :ok = assert_supervisor_quiescent(supervisor)
  end

  test "waits for stale child records after confirmed process termination" do
    {worker, monitor} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}
    # Model the independent supervisor exit signal arriving after its first
    # query. The worker is already dead, but its first child record remains.
    table = start_supervised!({ChildTable, [[worker], []]})
    assert :ok = assert_supervisor_quiescent(table)
  end

  test "reports live children and does not kill them or retain monitors" do
    supervisor = start_supervised!(Task.Supervisor)
    {:ok, worker} = Task.Supervisor.start_child(supervisor, fn -> receive do: (:stop -> :ok) end)
    before = Process.info(self(), :monitors)

    error =
      assert_raise ExUnit.AssertionError, fn ->
        assert_supervisor_quiescent(supervisor, 0)
      end

    assert error.message =~ inspect(worker)
    assert error.message =~ "current_function"
    assert Process.alive?(worker)
    assert Process.info(self(), :monitors) == before
    send(worker, :stop)
    assert :ok = assert_supervisor_quiescent(supervisor)
  end
end
