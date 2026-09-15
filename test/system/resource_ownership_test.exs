defmodule JidoActionTest.System.ResourceOwnershipTest do
  use ExUnit.Case, async: true
  @moduletag :system

  alias Jido.Exec
  alias JidoActionTest.Fixtures.Execution.SessionOwner

  # This service deliberately does not monitor clients. A dead Action cannot
  # release a session just by exiting, as with an external service.
  defmodule Service do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    @impl true
    def init(opts),
      do:
        {:ok,
         Map.merge(
           %{active: MapSet.new(), releases: %{}, hold_open: false, release: :ok},
           Map.new(opts)
         )}

    @impl true
    def handle_call({:open, id}, from, state) do
      state = %{state | active: MapSet.put(state.active, id)}
      send(state.observer, {:opened, id, from})
      if state.hold_open, do: {:noreply, state}, else: {:reply, {:ok, id}, state}
    end

    def handle_call({:release, id}, from, state) do
      send(state.observer, {:release_requested, id, from})

      case state.release do
        :ok ->
          state = %{
            state
            | active: MapSet.delete(state.active, id),
              releases: Map.update(state.releases, id, 1, &(&1 + 1))
          }

          {:reply, :ok, state}

        :hold ->
          {:noreply, state}

        {:error, _reason} = error ->
          {:reply, error, state}
      end
    end

    def handle_call(:snapshot, _from, state), do: {:reply, state, state}
  end

  defmodule UseSession do
    use Jido.Action, name: "example_use_owned_session"
    @impl true
    def run(params, context) do
      with {:ok, owner, id} <-
             SessionOwner.open(context.sessions, context.service, context.observer) do
        send(context.observer, {:using, id, self(), owner})

        receive do
          :finish -> Map.get(params, :result, {:ok, %{session: id}})
        end
      end
    end
  end

  setup do
    sessions = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    tasks = start_supervised!(Task.Supervisor)
    %{sessions: sessions, tasks: tasks}
  end

  test "normal completion releases the service session exactly once", context do
    {handle, service} = start_call(context)

    try do
      assert_receive {:using, id, worker, owner}, 1_000
      monitor = Process.monitor(owner)
      send(worker, :finish)
      assert {:ok, %{session: ^id}} = Exec.await(handle)
      assert_released(service, id, owner, monitor)
    after
      Exec.cancel(handle)
    end
  end

  test "cancellation kills the Action but the independent owner releases the session", context do
    {handle, service} = start_call(context)

    try do
      assert_receive {:using, id, worker, owner}, 1_000
      worker_monitor = Process.monitor(worker)
      owner_monitor = Process.monitor(owner)
      assert :ok = Exec.cancel(handle)
      assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _reason}, 1_000
      assert_released(service, id, owner, owner_monitor)
    after
      Exec.cancel(handle)
    end
  end

  test "cancellation during acquisition still releases an acquired session", context do
    {handle, service} = start_call(context, hold_open: true)

    try do
      assert_receive {:opened, id, from}, 1_000
      {owner, _tag} = from
      monitor = Process.monitor(owner)
      assert :ok = Exec.cancel(handle)
      assert MapSet.member?(GenServer.call(service, :snapshot).active, id)
      # The service has allocated the session, but has not acknowledged it.
      # The owner survives the Action and records the response before cleanup.
      GenServer.reply(from, {:ok, id})
      assert_released(service, id, owner, monitor)
      refute_received {:using, ^id, _, _}
    after
      Exec.cancel(handle)
    end
  end

  test "an acquisition timeout releases the known session ID", context do
    {handle, service} = start_call(context, hold_open: true)

    try do
      assert_receive {:opened, id, {owner, _tag}}, 1_000
      monitor = Process.monitor(owner)
      assert {:error, _error} = Exec.await(handle, 3_000)
      assert_released(service, id, owner, monitor)
      refute_received {:using, ^id, _, _}
    after
      Exec.cancel(handle)
    end
  end

  test "a complete-call timeout also permits independent release", context do
    {handle, service} = start_call(context, [], %{}, timeout: 1_000)

    try do
      assert_receive {:using, id, _worker, owner}, 1_000
      monitor = Process.monitor(owner)
      assert {:error, %Jido.Action.Error.TimeoutError{}} = Exec.await(handle, 3_000)
      assert_released(service, id, owner, monitor)
    after
      Exec.cancel(handle)
    end
  end

  for release <- [{:error, :unavailable}, :hold] do
    @tag release: release
    test "cleanup #{inspect(release)} does not replace the Action error",
         %{release: release} = context do
      original = Jido.Action.Error.execution_error("business failure", %{retry: false})
      {handle, service} = start_call(context, [release: release], %{result: {:error, original}})

      try do
        assert_receive {:using, id, worker, owner}, 1_000
        monitor = Process.monitor(owner)
        send(worker, :finish)
        assert {:error, ^original} = Exec.await(handle)
        assert_receive {:release_requested, ^id, _from}, 1_000
        assert_receive {:session_cleanup, ^id, {:error, _reason}}, 2_000
        assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}, 1_000
        assert MapSet.member?(GenServer.call(service, :snapshot).active, id)
      after
        Exec.cancel(handle)
      end
    end
  end

  defp start_call(context, service_opts \\ [], params \\ %{}, exec_opts \\ []) do
    service = start_supervised!({Service, [observer: self()] ++ service_opts})
    runtime = %{sessions: context.sessions, service: service, observer: self()}

    {Exec.run_async(UseSession, params, runtime, [task_supervisor: context.tasks] ++ exec_opts),
     service}
  end

  defp assert_released(service, id, owner, monitor) do
    assert_receive {:session_cleanup, ^id, :ok}, 2_000
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}, 1_000
    snapshot = GenServer.call(service, :snapshot)
    refute MapSet.member?(snapshot.active, id)
    assert snapshot.releases[id] == 1
  end
end
