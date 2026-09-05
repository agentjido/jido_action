defmodule JidoActionTest.Exec.BlockedTelemetryTest do
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias Jido.Exec
  alias Jido.Exec.Telemetry
  alias Jido.Flow
  alias Jido.Flow.{Ref, Step, Subflow}
  alias JidoActionTest.Fixtures.Execution.BlockingAction

  defmodule ControlledAction do
    use Jido.Action, name: "blocked_telemetry_controlled"

    def run(_params, %{test_pid: owner, token: token}) do
      send(owner, {token, :action_started, self(), Telemetry.tracker()})

      receive do
        {^token, :finish, result} -> result
      end
    end
  end

  defmodule ChildFlow do
    use Jido.Flow, name: "blocked_telemetry_child"

    flow do
      step "work", action: ControlledAction, params: %{}
      output result("work")
    end
  end

  setup do
    supervisor = __MODULE__.TaskSupervisor
    start_supervised!({Task.Supervisor, name: supervisor})
    %{supervisor: supervisor}
  end

  test "a complete-call timeout stops work before a blocked start handler is released", %{
    supervisor: supervisor
  } do
    token = attach_blocking([:jido, :action, :start])
    owner = self()

    {caller, caller_monitor} =
      spawn_caller(fn ->
        result =
          Exec.run(BlockingAction, %{value: 1}, %{test_pid: owner},
            timeout: 1_000,
            task_supervisor: __MODULE__.TaskSupervisor
          )

        send(owner, {token, :result, result})
      end)

    assert_receive {^token, :handler_blocked, handler}, 1_000
    handler_monitor = Process.monitor(handler)
    assert {:monitors, [{:process, worker}]} = Process.info(caller, :monitors)
    worker_monitor = Process.monitor(worker)
    assert {:links, [tracker]} = Process.info(caller, :links)
    tracker_monitor = Process.monitor(tracker)

    assert_receive {^token, :result, {:error, %Jido.Action.Error.TimeoutError{}}}, 3_000
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _reason}, 1_000
    assert_receive {:DOWN, ^handler_monitor, :process, ^handler, _reason}, 1_000
    assert_receive {:DOWN, ^tracker_monitor, :process, ^tracker, _reason}, 1_000
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, 1_000
    assert_receive {:blocking_flow_node_started, action}, 1_000
    assert_down(Process.monitor(action), action)
    assert Task.Supervisor.children(supervisor) == []
    refute_received {^token, :handler_released}
  end

  for operation <- [:cancel, :await_timeout] do
    @tag operation: operation
    test "#{operation} stops active work while the start handler is blocked", %{
      operation: operation,
      supervisor: supervisor
    } do
      token = attach_blocking([:jido, :action, :start], true)
      monitors_before = Process.info(self(), :monitors)

      handle =
        Exec.run_async(ControlledAction, %{}, %{test_pid: self(), token: token},
          task_supervisor: __MODULE__.TaskSupervisor
        )

      on_exit(fn -> Process.exit(handle.pid, :kill) end)
      assert_receive {^token, :handler_blocked, handler}, 1_000
      assert_receive {^token, :action_started, action, tracker}, 1_000
      guard = :sys.get_state(tracker).delivery_guard
      owned = monitor_processes([handler, action, tracker, guard])
      caller_monitor = Process.monitor(handle.pid)

      case operation do
        :cancel ->
          assert :ok = Exec.cancel(handle)

        :await_timeout ->
          assert {:error, %Jido.Exec.Error.AsyncTimeoutError{}} = Exec.await(handle, 0)
      end

      assert_receive {:DOWN, ^caller_monitor, :process, _, :normal}, 1_000
      assert_stopped(owned)
      assert Task.Supervisor.children(supervisor) == []
      assert Process.info(self(), :monitors) == monitors_before
      refute_received {^token, :handler_released}
      refute_received {:jido_exec_async_result, _, _, _}
      refute_received {:DOWN, _, :process, _, _}
    end
  end

  for {mode, reason} <- [sync: :shutdown, sync: :killed, async: :normal, async: :killed] do
    @tag mode: mode, reason: reason
    test "#{mode} owner exit (#{reason}) stops a blocked handler and active work", %{
      mode: mode,
      reason: reason,
      supervisor: supervisor
    } do
      token = attach_blocking([:jido, :action, :start])
      owner = self()

      {caller, caller_monitor} =
        spawn_caller(fn ->
          context = %{test_pid: owner, token: token}

          case mode do
            :sync ->
              Exec.run(ControlledAction, %{}, context,
                timeout: 10_000,
                task_supervisor: __MODULE__.TaskSupervisor
              )

            :async ->
              handle =
                Exec.run_async(ControlledAction, %{}, context,
                  task_supervisor: __MODULE__.TaskSupervisor
                )

              send(owner, {token, :handle, handle.pid})

              receive do
                {^token, :exit} -> :ok
              end
          end
        end)

      assert_receive {^token, :handler_blocked, handler}, 1_000
      assert_receive {^token, :action_started, action, tracker}, 1_000
      owned = monitor_processes([handler, action, tracker])

      controller =
        if mode == :async do
          assert_receive {^token, :handle, pid}, 1_000
          monitor_processes([pid])
        else
          []
        end

      case {mode, reason} do
        {:async, :normal} -> send(caller, {token, :exit})
        {_, :killed} -> Process.exit(caller, :kill)
        {:sync, :shutdown} -> Process.exit(caller, :shutdown)
      end

      assert_receive {:DOWN, ^caller_monitor, :process, ^caller, ^reason}, 1_000
      assert_stopped(owned ++ controller)
      assert Task.Supervisor.children(supervisor) == []
      refute_received {^token, :handler_released}
    end
  end

  test "nested work keeps the complete-call deadline while a target handler is blocked", %{
    supervisor: supervisor
  } do
    token = attach_blocking([:jido, :flow, :target, :start])
    owner = self()

    flow =
      Flow.new!(
        name: "blocked_telemetry_parent",
        components: [Subflow.new!(name: "child", flow: ChildFlow)],
        output: Ref.result("child")
      )

    {caller, caller_monitor} =
      spawn_caller(fn ->
        result =
          Exec.run(flow, %{}, %{test_pid: owner, token: token},
            timeout: 1_000,
            task_supervisor: __MODULE__.TaskSupervisor
          )

        send(owner, {token, :result, result})
      end)

    assert_receive {^token, :handler_blocked, handler}, 1_000
    assert_receive {^token, :action_started, action, tracker}, 1_000
    owned = monitor_processes([handler, action, tracker])

    assert_receive {^token, :result, {:error, %Jido.Flow.Error.TimeoutError{timeout: 1_000}}},
                   3_000

    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, 1_000
    assert_stopped(owned)
    assert Task.Supervisor.children(supervisor) == []
    refute_received {^token, :handler_released}
  end

  for suffix <- [:stop, :error] do
    @tag suffix: suffix
    test "a blocked #{suffix} handler does not prevent a terminal result", %{
      suffix: suffix,
      supervisor: supervisor
    } do
      token = attach_blocking([:jido, :action, suffix])
      owner = self()

      {caller, caller_monitor} =
        spawn_caller(fn ->
          result =
            Exec.run(ControlledAction, %{}, %{test_pid: owner, token: token},
              timeout: 10_000,
              task_supervisor: __MODULE__.TaskSupervisor
            )

          send(owner, {token, :result, result})
        end)

      assert_receive {^token, :action_started, action, tracker}, 1_000
      owned = monitor_processes([action, tracker])

      result =
        if suffix == :stop,
          do: {:ok, %{value: 1}},
          else: {:error, Jido.Action.Error.execution_error("test failure")}

      send(action, {token, :finish, result})
      assert_receive {^token, :handler_blocked, handler}, 1_000
      handler_monitor = Process.monitor(handler)
      assert_receive {^token, :result, ^result}, 1_000
      assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, 1_000
      assert_stopped([{handler, handler_monitor} | owned])
      assert Task.Supervisor.children(supervisor) == []
      refute_received {^token, :handler_released}
    end
  end

  for failure <- [:raise, :kill] do
    @tag failure: failure
    test "a handler #{failure} does not fail execution or leave delivery work", %{
      failure: failure,
      supervisor: supervisor
    } do
      token = make_ref()
      handler_id = {__MODULE__, token}

      :ok =
        :telemetry.attach(
          handler_id,
          [:jido, :action, :start],
          &__MODULE__.handle_failure/4,
          {self(), token, failure}
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      handle =
        Exec.run_async(ControlledAction, %{}, %{test_pid: self(), token: token},
          task_supervisor: __MODULE__.TaskSupervisor
        )

      on_exit(fn -> Process.exit(handle.pid, :kill) end)
      assert_receive {^token, :handler_failed, handler}, 1_000
      assert_receive {^token, :action_started, action, tracker}, 1_000
      owned = monitor_processes([handler, action, tracker])
      send(action, {token, :finish, {:ok, %{value: 1}}})
      assert {:ok, %{value: 1}} = Exec.await(handle, 1_000)
      assert_stopped(owned)
      assert Task.Supervisor.children(supervisor) == []
    end
  end

  test "managed success and failure preserve event order, nesting, and correlation" do
    token = make_ref()
    handler_id = {__MODULE__, token}
    prefixes = [[:jido, :flow], [:jido, :flow, :node], [:jido, :flow, :target]]
    events = for prefix <- prefixes, suffix <- [:start, :stop, :error], do: prefix ++ [suffix]
    :ok = :telemetry.attach_many(handler_id, events, &__MODULE__.handle_event/4, {self(), token})
    on_exit(fn -> :telemetry.detach(handler_id) end)

    for suffix <- [:stop, :error] do
      flow =
        Flow.new!(
          name: "managed_telemetry",
          components: [Step.new!(name: "work", action: ControlledAction)],
          output: Ref.result("work")
        )

      handle =
        Exec.run_async(flow, %{}, %{test_pid: self(), token: token},
          task_supervisor: __MODULE__.TaskSupervisor
        )

      on_exit(fn -> Process.exit(handle.pid, :kill) end)
      assert_receive {^token, :action_started, action, _tracker}, 1_000

      result =
        if suffix == :stop,
          do: {:ok, %{value: 1}},
          else: {:error, Jido.Action.Error.execution_error("test failure")}

      send(action, {token, :finish, result})

      case suffix do
        :stop ->
          assert ^result = Exec.await(handle, 1_000)

        :error ->
          assert {:error, %Jido.Action.Error.ExecutionFailureError{message: "test failure"}} =
                   Exec.await(handle, 1_000)
      end

      recorded =
        for _index <- 1..6 do
          assert_receive {^token, :event, event, measurements, metadata}
          {event, measurements, metadata}
        end

      expected =
        Enum.map(prefixes, &(&1 ++ [:start])) ++
          Enum.map(Enum.reverse(prefixes), &(&1 ++ [suffix]))

      assert Enum.map(recorded, &elem(&1, 0)) == expected
      assert [_id] = recorded |> Enum.map(&elem(&1, 2).execution_id) |> Enum.uniq()

      for {start, terminal} <-
            Enum.zip(Enum.take(recorded, 3), Enum.reverse(Enum.drop(recorded, 3))) do
        assert elem(start, 2) == Map.drop(elem(terminal, 2), [:error, :error_type])
        assert elem(terminal, 1).duration >= 0
      end

      refute_received {^token, :event, _, _, _}
    end
  end

  test "tracker death stops a blocked handler that traps exits", %{supervisor: supervisor} do
    token = attach_blocking([:jido, :action, :start], true)

    handle =
      Exec.run_async(ControlledAction, %{}, %{test_pid: self(), token: token},
        task_supervisor: __MODULE__.TaskSupervisor
      )

    on_exit(fn -> Process.exit(handle.pid, :kill) end)
    assert_receive {^token, :handler_blocked, handler}, 1_000
    on_exit(fn -> Process.exit(handler, :kill) end)
    assert_receive {^token, :action_started, action, tracker}, 1_000
    guard = :sys.get_state(tracker).delivery_guard
    owned = monitor_processes([handler, action, tracker, guard])

    Process.exit(tracker, :kill)

    assert {:error, %Jido.Exec.Error.AsyncExecutionError{}} = Exec.await(handle, 1_000)
    assert_stopped(owned)
    assert Task.Supervisor.children(supervisor) == []
    refute_received {^token, :handler_released}
  end

  for terminal <- [:cancel, :supervisor_shutdown] do
    @tag terminal: terminal
    test "nested #{terminal} stops delivery and its owner guard without handler release", %{
      terminal: terminal,
      supervisor: supervisor
    } do
      token = attach_blocking([:jido, :flow, :target, :start], true)

      flow =
        Flow.new!(
          name: "blocked_telemetry_parent",
          components: [Subflow.new!(name: "child", flow: ChildFlow)],
          output: Ref.result("child")
        )

      handle =
        Exec.run_async(flow, %{}, %{test_pid: self(), token: token},
          task_supervisor: __MODULE__.TaskSupervisor
        )

      on_exit(fn -> Process.exit(handle.pid, :kill) end)
      assert_receive {^token, :handler_blocked, handler}, 1_000
      on_exit(fn -> Process.exit(handler, :kill) end)
      assert_receive {^token, :action_started, action, tracker}, 1_000
      guard = :sys.get_state(tracker).delivery_guard
      owned = monitor_processes([handler, action, tracker, guard, handle.pid])

      case terminal do
        :cancel ->
          assert :ok = Exec.cancel(handle)
          assert Task.Supervisor.children(supervisor) == []

        :supervisor_shutdown ->
          stop_supervised!(supervisor)
          assert {:error, %Jido.Exec.Error.AsyncExecutionError{}} = Exec.await(handle, 1_000)
          assert Process.whereis(supervisor) == nil
      end

      assert_stopped(owned)
      refute_received {^token, :handler_released}
    end
  end

  test "event delivery keeps caller Logger metadata and group leader" do
    token = make_ref()
    handler_id = {__MODULE__, token}
    events = [[:jido, :action, :start], [:jido, :action, :stop]]
    group_leader = Process.group_leader()
    Logger.metadata(ansi_color: :magenta)

    :ok =
      :telemetry.attach_many(handler_id, events, &__MODULE__.handle_context/4, {self(), token})

    on_exit(fn -> :telemetry.detach(handler_id) end)

    for mode <- [:sync, :async] do
      target = JidoActionTest.Fixtures.Actions.Add
      opts = [timeout: 1_000, task_supervisor: __MODULE__.TaskSupervisor]

      result =
        case mode do
          :sync -> Exec.run(target, %{value: 1}, %{}, opts)
          :async -> target |> Exec.run_async(%{value: 1}, %{}, opts) |> Exec.await(1_000)
        end

      assert {:ok, %{value: 2}} = result

      for event <- events do
        assert_receive {^token, :context, ^event, metadata, ^group_leader}, 1_000
        assert metadata[:ansi_color] == :magenta
      end
    end
  end

  def handle_blocked(_event, _measurements, _metadata, {owner, token, trap_exits?}) do
    if trap_exits?, do: Process.flag(:trap_exit, true)
    send(owner, {token, :handler_blocked, self()})

    receive do
      {^token, :release} -> send(owner, {token, :handler_released})
    end
  end

  def handle_failure(_event, _measurements, _metadata, {owner, token, failure}) do
    send(owner, {token, :handler_failed, self()})

    case failure do
      :raise -> raise "handler failed"
      :kill -> Process.exit(self(), :kill)
    end
  end

  def handle_event(event, measurements, metadata, {owner, token}) do
    send(owner, {token, :event, event, measurements, metadata})
  end

  def handle_context(event, _measurements, _metadata, {owner, token}) do
    send(owner, {token, :context, event, Logger.metadata(), Process.group_leader()})
  end

  defp monitor_processes(pids), do: Enum.map(pids, &{&1, Process.monitor(&1)})

  defp assert_stopped(processes) do
    for {pid, monitor} <- processes, do: assert_down(monitor, pid)
  end

  defp assert_down(monitor, pid) do
    assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 1_000
  end

  defp attach_blocking(event, trap_exits? \\ false) do
    token = make_ref()
    handler_id = {__MODULE__, token}

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        &__MODULE__.handle_blocked/4,
        {self(), token, trap_exits?}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    token
  end

  defp spawn_caller(fun) do
    {caller, monitor} = spawn_monitor(fun)
    on_exit(fn -> Process.exit(caller, :kill) end)
    {caller, monitor}
  end
end
