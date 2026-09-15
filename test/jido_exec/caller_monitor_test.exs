defmodule JidoActionTest.Exec.CallerMonitorTest do
  use ExUnit.Case, async: false

  alias Jido.Action.Error.ExecutionFailureError
  alias Jido.Exec
  alias Jido.Flow
  alias Jido.Flow.{Ref, Subflow}

  @moduletag capture_log: true

  defmodule HeldAction do
    use Jido.Action, name: "caller_monitor_held_action"

    @impl true
    def run(params, %{test_pid: test_pid, token: token}) do
      Process.flag(:trap_exit, true)
      send(test_pid, {token, :ready, self()})

      receive do
        {^token, :release} -> {:ok, params}
      end
    end
  end

  defmodule HeldFlow do
    use Jido.Flow, name: "caller_monitor_child"

    flow do
      step "held",
        action: JidoActionTest.Exec.CallerMonitorTest.HeldAction,
        params: %{value: input(:value)}

      output result("held")
    end
  end

  setup do
    supervisor = start_supervised!(Task.Supervisor)
    trace_spawns(supervisor)
    %{supervisor: supervisor, token: make_ref()}
  end

  for mode <- [:action, :managed_action, :nested_flow],
      outcome <- [:success, :failure, :caller_exit] do
    @tag mode: mode, outcome: outcome
    test "#{mode} stops caller guards after #{outcome}",
         %{mode: mode, outcome: outcome} = context do
      %{supervisor: supervisor, token: token} = context
      owner = self()
      {target, opts} = execution(mode, supervisor)

      {caller, caller_monitor} =
        spawn_monitor(fn ->
          receive do
            {^token, :run} ->
              result = Exec.run(target, %{value: 1}, %{test_pid: owner, token: token}, opts)
              send(owner, {token, :result, result})
              await_inspection(owner, token)
          end
        end)

      on_exit(fn -> Process.exit(caller, :kill) end)
      trace_spawns(caller)
      send(caller, {token, :run})
      assert_receive {^token, :ready, worker}, 1_000
      worker_monitor = monitor_process(worker)
      guards = capture_guards(caller, worker, mode != :action)

      case outcome do
        :success ->
          send(worker, {token, :release})
          assert_receive {^token, :result, {:ok, %{value: 1}}}, 1_000
          assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :normal}, 1_000

        :failure ->
          Process.exit(worker, :kill)

          assert_receive {^token, :result,
                          {:error,
                           %ExecutionFailureError{
                             message: "action execution process exited",
                             details: %{action: HeldAction, reason: :killed, retry: false}
                           }}},
                         1_000

          assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 1_000

        :caller_exit ->
          Process.exit(caller, :kill)
          assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}, 1_000
          assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 1_000
      end

      await_guards(guards)

      if outcome != :caller_exit do
        # Guard DOWN is the barrier before checking the surviving caller.
        assert {:monitored_by, [owner]} = Process.info(caller, :monitored_by)
        assert owner == self()
        send(caller, {token, :inspect})
        assert_receive {^token, :caller_state, {:monitors, []}, {:messages, []}}, 1_000
        assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, 1_000
      end

      assert Task.Supervisor.children(supervisor) == []
      refute_received {^token, :result, _result}
    end
  end

  for mode <- [:managed_action, :nested_flow], order <- [:cancel_first, :complete_first, :race] do
    @tag mode: mode, order: order
    test "#{mode} stops guards when cancellation order is #{order}",
         %{mode: mode, order: order} = context do
      %{supervisor: supervisor, token: token} = context
      {target, opts} = execution(mode, supervisor)
      {:monitors, initial_monitors} = Process.info(self(), :monitors)
      handle = Exec.run_async(target, %{value: 1}, %{test_pid: self(), token: token}, opts)
      on_exit(fn -> Process.exit(handle.pid, :kill) end)
      assert_receive {^token, :ready, worker}, 1_000
      worker_monitor = monitor_process(worker)
      guards = capture_guards(handle.pid, worker, true)
      %{pid: pid, monitor_ref: handle_monitor} = handle

      case order do
        :cancel_first ->
          assert :ok = Exec.cancel(handle)
          assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 1_000

        :complete_first ->
          send(worker, {token, :release})
          assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :normal}, 1_000
          assert_receive {:DOWN, ^handle_monitor, :process, ^pid, :normal}, 1_000
          assert :ok = Exec.cancel(handle)

        :race ->
          send(worker, {token, :release})
          assert :ok = Exec.cancel(handle)
          assert_receive {:DOWN, ^worker_monitor, :process, ^worker, reason}, 1_000
          assert reason in [:normal, :killed]
      end

      await_guards(guards)
      assert :ok = Exec.cancel(handle)
      assert {:error, %Jido.Exec.Error.InvalidHandleError{}} = Exec.await(handle, 0)
      assert Task.Supervisor.children(supervisor) == []
      assert {:monitors, ^initial_monitors} = Process.info(self(), :monitors)
      refute_received {:jido_exec_async_result, _, _, _}
      refute_received {:DOWN, _, :process, _, _}
    end
  end

  defp execution(mode, supervisor) do
    timeout = if mode == :action, do: :infinity, else: 10_000
    target = if mode == :nested_flow, do: nested_flow(), else: HeldAction
    {target, [task_supervisor: supervisor, timeout: timeout, max_concurrency: 1]}
  end

  defp nested_flow do
    Flow.new!(
      name: "caller_monitor_parent",
      components: [Subflow.new!(name: "child", flow: HeldFlow, params: Ref.input([]))],
      output: Ref.result("child")
    )
  end

  defp trace_spawns(pid) do
    :erlang.trace(pid, true, [:procs, :set_on_spawn, {:tracer, self()}])
  end

  defp capture_guards(caller, action_worker, managed?) do
    workers =
      if managed? do
        # Async control also monitors its owner. The other monitor owns work.
        {:monitors, monitors} = Process.info(caller, :monitors)
        [{:process, managed_worker}] = Enum.reject(monitors, &(&1 == {:process, self()}))
        [managed_worker, action_worker]
      else
        [action_worker]
      end

    for worker <- workers do
      on_exit(fn -> Process.exit(worker, :kill) end)
      # Each worker spawns its guard before it starts the held Action.
      assert_receive {:trace, ^worker, :spawn, guard, _entry}, 1_000
      on_exit(fn -> Process.exit(guard, :kill) end)
      {guard, monitor_process(guard)}
    end
  end

  defp monitor_process(pid) do
    monitor = Process.monitor(pid)
    assert {:monitored_by, monitors} = Process.info(pid, :monitored_by)
    assert self() in monitors
    monitor
  end

  defp await_guards(guards) do
    for {guard, monitor} <- guards do
      assert_receive {:DOWN, ^monitor, :process, ^guard, :normal}, 1_000
      refute Process.alive?(guard)
    end
  end

  defp await_inspection(owner, token) do
    receive do
      {^token, :inspect} ->
        send(owner, {
          token,
          :caller_state,
          Process.info(self(), :monitors),
          Process.info(self(), :messages)
        })
    end
  end
end
