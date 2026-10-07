defmodule JidoActionTest.Exec.ScopedExecutionTest do
  use ExUnit.Case, async: false

  alias Jido.Exec
  alias Jido.Flow.{Ref}

  @moduletag capture_log: true

  defmodule Echo do
    use Jido.Action, name: "scope_echo"
    def run(params, _context), do: {:ok, Map.put(params, :action_pid, self())}
  end

  defmodule ValidatedFlow do
    @behaviour Jido.Flow

    def flow do
      JidoActionTest.FlowBuilder.new!(
        name: "scope_validators",
        components: [
          JidoActionTest.FlowComponent.step!(name: "echo", action: Echo, params: Ref.input([]))
        ],
        output: Ref.result("echo")
      )
    end

    def validate_params(params) do
      prior = Process.get(:scope_action_state)
      Process.put(:scope_validator_state, true)
      {:ok, Map.merge(params, %{input_pid: self(), prior: prior})}
    end

    def validate_output(output), do: {:ok, Map.put(output, :output_pid, self())}
  end

  defmodule First do
    use Jido.Action, name: "scope_first"

    def run(_params, _context) do
      Process.put(:scope_action_state, :dirty)
      {:continue, %{first_pid: self()}, ValidatedFlow}
    end
  end

  defmodule Held do
    use Jido.Action, name: "scope_held"

    def run(%{id: id}, %{owner: owner, ref: ref}) do
      Process.flag(:trap_exit, true)
      send(owner, {ref, :ready, id, self()})

      receive do
        {^ref, :release} ->
          send(owner, {ref, :effect, id})
          {:ok, %{id: id}}
      end
    end
  end

  defmodule KillFirst do
    use Jido.Action, name: "scope_kill_first"
    def run(%{value: 1}, _context), do: Process.exit(self(), :kill)
    def run(params, _context), do: {:ok, params, [:kept]}
  end

  setup do
    supervisor = start_supervised!(Task.Supervisor)
    %{supervisor: supervisor, ref: make_ref()}
  end

  test "untimed Flow validators run outside the caller", %{supervisor: supervisor} do
    {:ok, output} = Exec.run(ValidatedFlow, %{}, %{}, task_supervisor: supervisor)
    refute output.input_pid == self()
    assert output.input_pid == output.output_pid
    refute output.action_pid == output.input_pid
    refute Process.get(:scope_validator_state)
  end

  test "a continued Flow cannot inherit a completed Action process", %{supervisor: supervisor} do
    {:ok, output} = Exec.run(First, %{}, %{}, task_supervisor: supervisor, timeout: 5_000)
    assert output.prior == nil
    refute Process.alive?(output.first_pid)
    refute output.first_pid == output.input_pid
  end

  test "paused Flow operations isolate their validators", %{supervisor: supervisor} do
    {:ok, execution} = Exec.start(ValidatedFlow, %{}, %{}, task_supervisor: supervisor)
    {:ok, execution} = Exec.continue(execution)
    {:ok, output} = Exec.result(execution)
    refute output.input_pid == self()
    refute output.output_pid == self()
    refute Process.get(:scope_validator_state)
    assert Task.Supervisor.children(supervisor) == []
  end

  test "a compound failure stops its Actions even when the Flow scheduler is suspended",
       context do
    %{supervisor: supervisor, ref: ref} = context
    owner = self()
    attach(ref, [[:jido, :flow, :reduce, :item, :start]])

    flow =
      JidoActionTest.FlowBuilder.new!(
        name: "scope_compound",
        components:
          for(
            id <- ["a", "b"],
            do:
              JidoActionTest.FlowComponent.reduce!(
                name: id,
                collection: [1],
                initial: %{},
                action: Held,
                params: %{id: id}
              )
          ),
        output: %{}
      )

    caller =
      Task.async(fn ->
        Exec.run(flow, %{}, %{owner: owner, ref: ref}, task_supervisor: supervisor)
      end)

    actions =
      for id <- ["a", "b"], into: %{} do
        assert_receive {^ref, :ready, ^id, action}, 2_000
        on_exit(fn -> Process.exit(action, :kill) end)
        {id, action}
      end

    assert_receive {^ref, :event, _, %{node: "a"}, wrapper}, 2_000
    {:dictionary, dictionary} = Process.info(wrapper, :dictionary)
    flow_worker = hd(dictionary[:"$callers"])
    monitors = for pid <- [flow_worker | Map.values(actions)], do: {pid, Process.monitor(pid)}

    # The failure must reach the controller without waiting for the scheduler.
    :erlang.suspend_process(flow_worker)
    Process.exit(wrapper, :kill)
    assert {:error, _} = Task.await(caller)

    for {pid, monitor} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 1_000
    end

    refute_received {^ref, :effect, _}
    assert Task.Supervisor.children(supervisor) == []
  end

  test "nested target spans have unique identities and full paths", %{
    supervisor: supervisor,
    ref: ref
  } do
    attach(ref, [[:jido, :flow, :target, :start], [:jido, :flow, :target, :stop]])

    flow =
      JidoActionTest.FlowBuilder.new!(
        name: "scope_nested",
        components:
          for(
            name <- ["left", "right"],
            do: JidoActionTest.FlowComponent.subflow!(name: name, flow: ValidatedFlow)
          ),
        output: %{}
      )

    assert {:ok, %{}} = Exec.run(flow, %{}, %{}, task_supervisor: supervisor)
    events = drain(ref)
    starts = for {[:jido, :flow, :target, :start], metadata, _} <- events, do: metadata
    stops = for {[:jido, :flow, :target, :stop], metadata, _} <- events, do: metadata
    assert Enum.sort(Enum.map(starts, & &1.node_path)) == [["left", "echo"], ["right", "echo"]]
    assert length(Enum.uniq(Enum.map(starts, & &1.span_id))) == 2
    assert Enum.sort(Enum.map(starts, & &1.span_id)) == Enum.sort(Enum.map(stops, & &1.span_id))
    assert Enum.all?(starts, &is_reference(&1.parent_span_id))
  end

  for failure <- [:control, :private_supervisor, :flow] do
    @tag failure: failure
    test "#{failure} death stops trapping Action Tasks", %{
      supervisor: supervisor,
      ref: ref,
      failure: failure
    } do
      flow =
        JidoActionTest.FlowBuilder.new!(
          name: "scope_failures",
          components:
            for(
              id <- ["a", "b"],
              do: JidoActionTest.FlowComponent.step!(name: id, action: Held, params: %{id: id})
            ),
          output: %{}
        )

      handle = Exec.run_async(flow, %{}, %{owner: self(), ref: ref}, task_supervisor: supervisor)

      workers =
        for id <- ["a", "b"] do
          assert_receive {^ref, :ready, ^id, worker}, 1_000
          {worker, Process.monitor(worker)}
        end

      [{worker, _} | _] = workers
      {:dictionary, dictionary} = Process.info(worker, :dictionary)
      private = hd(dictionary[:"$ancestors"])
      flow_worker = hd(dictionary[:"$callers"])
      private_monitor = Process.monitor(private)

      victim =
        case failure do
          :control -> handle.pid
          :private_supervisor -> private
          :flow -> flow_worker
        end

      Process.exit(victim, :kill)
      assert {:error, error} = Exec.await(handle)
      assert error.details.reason == :killed

      for {pid, monitor} <- workers do
        assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 1_000
        refute Process.alive?(pid)
      end

      assert_receive {:DOWN, ^private_monitor, :process, ^private, _}, 1_000
      assert Task.Supervisor.children(supervisor) == []
      refute_received {^ref, :effect, _}
    end
  end

  test "Map collect_errors retains hard Action failures as item data", %{supervisor: supervisor} do
    flow =
      JidoActionTest.FlowBuilder.new!(
        name: "scope_collect_kill",
        components: [
          JidoActionTest.FlowComponent.map!(
            name: "items",
            collection: [1, 2, 3],
            action: KillFirst,
            params: %{value: Ref.item()},
            on_error: :collect_errors
          )
        ],
        output: %{items: Ref.result("items")}
      )

    for limit <- [1, 2] do
      assert {:ok,
              %{
                items: [
                  failure,
                  %{status: :ok, value: %{value: 2}},
                  %{status: :ok, value: %{value: 3}}
                ]
              }, [:kept, :kept]} =
               Exec.run(flow, %{}, %{}, task_supervisor: supervisor, max_concurrency: limit)

      assert %{
               status: :error,
               error: %{
                 details: %{
                   reason: :killed,
                   item_index: 0,
                   target: KillFirst,
                   phase: :map_target_execution
                 }
               }
             } = failure
    end
  end

  test "one host slot supports parallel Actions without wrapper Tasks", %{ref: ref} do
    supervisor =
      start_supervised!(Supervisor.child_spec({Task.Supervisor, max_children: 1}, id: :limited))

    flow =
      JidoActionTest.FlowBuilder.new!(
        name: "scope_capacity",
        components:
          for(
            id <- ["a", "b"],
            do: JidoActionTest.FlowComponent.step!(name: id, action: Held, params: %{id: id})
          ),
        output: %{}
      )

    handle =
      Exec.run_async(flow, %{}, %{owner: self(), ref: ref},
        task_supervisor: supervisor,
        max_concurrency: 2
      )

    workers =
      for id <- ["a", "b"] do
        assert_receive {^ref, :ready, ^id, worker}, 1_000
        worker
      end

    assert Task.Supervisor.children(supervisor) == [handle.pid]
    {:dictionary, dictionary} = Process.info(hd(workers), :dictionary)
    private = hd(dictionary[:"$ancestors"])
    flow_worker = hd(dictionary[:"$callers"])
    assert Enum.sort(Task.Supervisor.children(private)) == Enum.sort([flow_worker | workers])
    Enum.each(workers, &send(&1, {ref, :release}))
    assert {:ok, %{}} = Exec.await(handle)
    refute Process.alive?(private)
  end

  test "completed calls release a single host slot before the next call", %{} do
    supervisor =
      start_supervised!(
        Supervisor.child_spec({Task.Supervisor, max_children: 1}, id: :sequential)
      )

    for _ <- 1..100 do
      assert {:ok, _} = Exec.run(Echo, %{}, %{}, task_supervisor: supervisor)
      assert Task.Supervisor.children(supervisor) == []
    end
  end

  test "paused executions detach scope data and use a new scope for each operation", %{
    supervisor: supervisor,
    ref: ref
  } do
    attach(ref, [[:jido, :flow, :target, :start]])

    flow =
      JidoActionTest.FlowBuilder.new!(
        name: "scope_paused",
        components: [
          JidoActionTest.FlowComponent.step!(name: "a", action: Echo),
          JidoActionTest.FlowComponent.step!(name: "b", action: Echo, needs: ["a"])
        ],
        output: %{}
      )

    assert {:ok, execution} = Exec.start(flow, %{}, %{}, task_supervisor: supervisor)
    assert_detached(execution)
    assert {:ok, _, execution} = Exec.step(execution)
    assert_receive {^ref, :event, _, %{node: "a"}, first}
    assert_detached(execution)
    assert {:ok, execution} = Exec.continue(execution)
    assert_receive {^ref, :event, _, %{node: "b"}, second}
    assert_detached(execution)
    refute first == second
    refute Process.alive?(first)
    refute Process.alive?(second)
    assert Task.Supervisor.children(supervisor) == []
  end

  test "zero timeout has one target-neutral type and dispatches no validators", %{
    supervisor: supervisor
  } do
    for target <- [
          Echo,
          ValidatedFlow,
          ValidatedFlow.flow(),
          Jido.Instruction.new!(target: ValidatedFlow)
        ] do
      assert {:error, %Jido.Exec.Error.TimeoutError{} = error} =
               Exec.run(target, %{}, %{}, task_supervisor: supervisor, timeout: 0)

      assert %{type: :execution_timeout, retryable?: false, details: %{timeout: 0}} =
               Jido.Exec.Error.to_map(error)
    end

    assert Task.Supervisor.children(supervisor) == []
  end

  defp assert_detached(execution) do
    assert execution.lifecycle.flow.owner == nil
    assert execution.lifecycle.flow.tracker == nil
    refute contains_scope?(execution)
  end

  defp contains_scope?(%{controller: controller, supervisor: supervisor})
       when is_pid(controller) and is_pid(supervisor),
       do: true

  defp contains_scope?(value) when is_function(value) do
    {:env, env} = Function.info(value, :env)
    contains_scope?(env)
  end

  defp contains_scope?(value) when is_map(value), do: value |> Map.to_list() |> contains_scope?()

  defp contains_scope?(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> contains_scope?()

  defp contains_scope?(value) when is_list(value), do: Enum.any?(value, &contains_scope?/1)
  defp contains_scope?(_value), do: false

  defp attach(ref, events) do
    :ok = :telemetry.attach_many(ref, events, &__MODULE__.event/4, {self(), ref})
    on_exit(fn -> :telemetry.detach(ref) end)
  end

  def event(event, _measurements, metadata, {owner, ref}),
    do: send(owner, {ref, :event, event, metadata, self()})

  defp drain(ref) do
    receive do
      {^ref, :event, event, metadata, pid} -> [{event, metadata, pid} | drain(ref)]
    after
      0 -> []
    end
  end
end
