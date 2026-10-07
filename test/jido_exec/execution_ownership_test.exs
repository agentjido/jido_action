defmodule JidoActionTest.Exec.ExecutionOwnershipTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true
  alias Jido.Exec
  alias Jido.Flow.{Ref}

  defmodule Probe do
    use Jido.Action, name: "ownership_probe"
    @impl true
    def run(params, %{observer: observer, token: token}) do
      send(observer, {token, :ready, self()})
      receive do: ({^token, :release} -> {:ok, params, [:effect]})
    end
  end

  for {mode, starts} <- [sync: 3, timed: 3, async: 3, serial: 6, timed_serial: 6, empty_map: 3] do
    @tag mode: mode
    test "#{mode} starts #{starts} framework processes with distinct Action Tasks", %{
      mode: mode
    } do
      supervisor = start_supervised!(Task.Supervisor)
      observer = self()
      token = make_ref()

      target =
        case mode do
          mode when mode in [:serial, :timed_serial] ->
            serial_flow()

          :empty_map ->
            JidoActionTest.FlowBuilder.new!(
              name: "empty_map",
              components: [
                JidoActionTest.FlowComponent.map!(name: "items", action: Probe, collection: [])
              ],
              output: %{value: 42}
            )

          _ ->
            Probe
        end

      count =
        if(mode == :empty_map, do: 0, else: if(mode in [:serial, :timed_serial], do: 3, else: 1))

      opts = [task_supervisor: supervisor, max_concurrency: 1]
      opts = if mode in [:timed, :timed_serial], do: [timeout: 5_000] ++ opts, else: opts

      {caller, caller_monitor} =
        spawn_monitor(fn ->
          receive do
            {^token, :start} ->
              context = %{observer: observer, token: token}

              result =
                if mode == :async do
                  handle = Exec.run_async(target, %{value: 42}, context, opts)
                  send(observer, {token, :controller, handle.pid})
                  Exec.await(handle)
                else
                  Exec.run(target, %{value: 42}, context, opts)
                end

              send(observer, {token, :result, result, Process.info(self(), :monitors)})
          end
        end)

      on_exit(fn -> Process.exit(caller, :kill) end)

      for pid <- [supervisor, caller],
          do: :erlang.trace(pid, true, [:procs, :set_on_spawn, {:tracer, self()}])

      send(caller, {token, :start})

      controller =
        if mode == :async do
          assert_receive {^token, :controller, controller}, 2_000
          controller
        else
          caller
        end

      workers =
        for _ <- List.duplicate(:invocation, count) do
          assert_receive {^token, :ready, worker}, 2_000

          # The controller already owns its worker PID and monitor. It needs
          # no ETS table to keep another copy of those values.
          assert for(
                   table <- :ets.all(),
                   :ets.info(table, :owner) in [controller, worker],
                   do: table
                 ) == []

          send(worker, {token, :release})
          worker
        end

      assert length(Enum.uniq(workers)) == count
      refute caller in workers

      expected_effects = List.duplicate(:effect, count)

      expected =
        if expected_effects == [],
          do: {:ok, %{value: 42}},
          else: {:ok, %{value: 42}, expected_effects}

      assert_receive {^token, :result, ^expected, {:monitors, []}}, 2_000

      assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}
      marker = :erlang.trace_delivered(:all)
      children = spawns(marker, []) |> Enum.uniq()

      for pid <- children do
        monitor = Process.monitor(pid)
        assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 1_000
      end

      assert length(children) == unquote(starts)
      assert Task.Supervisor.children(supervisor) == []
    end
  end

  defmodule Trap do
    use Jido.Action, name: "ownership_trap"
    @impl true
    def run(params, %{observer: observer, token: token}) do
      Process.flag(:trap_exit, true)
      send(observer, {token, :held, params.id, self()})
      receive do: ({^token, :release} -> {:ok, params})
    end
  end

  for boundary <- [:timed, :async, :concurrent, :paused] do
    @tag boundary: boundary
    test "#{boundary} work stops when its controller dies", %{boundary: boundary} do
      supervisor = start_supervised!(Task.Supervisor)
      observer = self()
      token = make_ref()

      flow =
        JidoActionTest.FlowBuilder.new!(
          name: "surviving_wave",
          components:
            for(
              id <- 1..2,
              do:
                JidoActionTest.FlowComponent.step!(
                  name: "s#{id}",
                  action: Trap,
                  params: %{id: id}
                )
            ),
          output: Ref.result("s2")
        )

      {caller, caller_monitor} =
        spawn_monitor(fn ->
          context = %{observer: observer, token: token}
          opts = [task_supervisor: supervisor, timeout: 5_000]

          case boundary do
            :timed ->
              Exec.run(Trap, %{id: 1}, context, opts)

            :async ->
              handle = Exec.run_async(Trap, %{id: 1}, context, opts)
              send(observer, {token, :controller, handle.pid})
              Exec.await(handle)

            :concurrent ->
              Exec.run(flow, %{}, context, task_supervisor: supervisor)

            :paused ->
              {:ok, execution} = Exec.start(flow, %{}, context, task_supervisor: supervisor)
              Exec.wave(execution)
          end
        end)

      on_exit(fn -> Process.exit(caller, :kill) end)

      workers =
        for _ <- 1..if(boundary in [:concurrent, :paused], do: 2, else: 1) do
          assert_receive {^token, :held, _, worker}, 1_000
          {worker, Process.monitor(worker)}
        end

      controller =
        if boundary == :async do
          assert_receive {^token, :controller, controller}
          controller
        else
          caller
        end

      scope_monitors =
        for pid <- Task.Supervisor.children(supervisor), do: {pid, Process.monitor(pid)}

      controller_monitor = Process.monitor(controller)
      Process.exit(controller, :kill)
      assert_receive {:DOWN, ^controller_monitor, :process, ^controller, :killed}, 1_000

      for {worker, monitor} <- workers do
        assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 1_000
      end

      assert_receive {:DOWN, ^caller_monitor, :process, ^caller, _}, 1_000

      for {pid, monitor} <- scope_monitors,
          do: assert_receive({:DOWN, ^monitor, :process, ^pid, _}, 1_000)

      assert Task.Supervisor.children(supervisor) == []
    end
  end

  test "direct and timed callbacks keep process state in their own Task" do
    Process.put(:ownership_value, :caller)
    assert {:ok, %{before: nil, pid: direct_worker}} = Exec.run(__MODULE__.LocalState)
    refute direct_worker == self()
    assert Process.get(:ownership_value) == :caller

    assert {:ok, %{before: nil, pid: worker}} =
             Exec.run(__MODULE__.LocalState, %{}, %{}, timeout: 5_000)

    refute worker == self()
    assert Process.get(:ownership_value) == :caller
    Process.delete(:ownership_value)
  end

  for terminal <- [:cancel, :timeout] do
    @tag terminal: terminal
    test "a living controller stops concurrent trapping workers on #{terminal}", %{
      terminal: terminal
    } do
      supervisor = start_supervised!(Task.Supervisor)
      token = make_ref()

      flow =
        JidoActionTest.FlowBuilder.new!(
          name: "controlled_wave",
          components:
            for(
              id <- 1..3,
              do:
                JidoActionTest.FlowComponent.step!(
                  name: "s#{id}",
                  action: Trap,
                  params: %{id: id}
                )
            ),
          output: Ref.result("s3")
        )

      handle =
        Exec.run_async(flow, %{}, %{observer: self(), token: token},
          task_supervisor: supervisor,
          max_concurrency: 2,
          timeout: if(terminal == :timeout, do: 1_000, else: :infinity)
        )

      workers =
        for _ <- 1..2 do
          assert_receive {^token, :held, _, worker}, 1_000
          {worker, Process.monitor(worker)}
        end

      if terminal == :cancel do
        assert :ok = Exec.cancel(handle)
      else
        assert {:error, %Jido.Flow.Error.TimeoutError{}} = Exec.await(handle, 3_000)
      end

      for {worker, monitor} <- workers do
        assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 1_000
      end

      assert Task.Supervisor.children(supervisor) == []
      refute_received {^token, :held, 3, _}
    end
  end

  test "a scheduler exception removes monitors for already admitted work" do
    supervisor = start_supervised!(Task.Supervisor)

    flow =
      JidoActionTest.FlowBuilder.new!(
        name: "interrupted_admission",
        components: [
          JidoActionTest.FlowComponent.step!(name: "first", action: Trap, params: %{id: 1}),
          JidoActionTest.FlowComponent.step!(name: "second", action: Trap, params: %{id: 2})
        ],
        output: Ref.result("second")
      )

    assert {:ok, execution} =
             Exec.start(flow, %{}, %{observer: self(), token: make_ref()},
               task_supervisor: supervisor,
               max_concurrency: 2
             )

    [_first, second] = execution.ready
    # Corrupt only the second metadata path, after the first worker is admitted.
    compiled = %{
      execution.compiled
      | work_index:
          Map.update!(
            execution.compiled.work_index,
            second.node.hash,
            &Map.put(&1, :component_path, [:invalid])
          ),
        component_index: Map.put(execution.compiled.component_index, :invalid, :invalid)
    }

    {:monitors, initial_monitors} = Process.info(self(), :monitors)

    ready = [hd(execution.ready), %{second | node: %{name: :invalid}}]

    assert {:error, %Jido.Flow.Error.InternalError{details: %{reason: {{:badkey, :hash, _}, _}}}} =
             Exec.wave(%{execution | compiled: compiled, ready: ready})

    assert Task.Supervisor.children(supervisor) == []
    assert Process.info(self(), :monitors) == {:monitors, initial_monitors}
    refute_received {:DOWN, _, :process, _, _}
  end

  defmodule LocalState do
    use Jido.Action, name: "ownership_local_state"
    @impl true
    def run(_params, _context) do
      before = Process.put(:ownership_value, :action)
      {:ok, %{before: before, pid: self()}}
    end
  end

  defp spawns(marker, children) do
    receive do
      {:trace_delivered, :all, ^marker} -> children
      {:trace, _parent, :spawn, child, _mfa} -> spawns(marker, [child | children])
      {:trace, _pid, _event, _info} -> spawns(marker, children)
      {:trace, _pid, _event, _info, _other} -> spawns(marker, children)
    after
      1_000 -> flunk("trace barrier missing")
    end
  end

  defp serial_flow do
    JidoActionTest.FlowBuilder.new!(
      name: "three_serial_actions",
      components: [
        JidoActionTest.FlowComponent.step!(name: "one", action: Probe, params: Ref.input([])),
        JidoActionTest.FlowComponent.step!(name: "two", action: Probe, params: Ref.result("one")),
        JidoActionTest.FlowComponent.step!(
          name: "three",
          action: Probe,
          params: Ref.result("two")
        )
      ],
      output: Ref.result("three")
    )
  end
end
