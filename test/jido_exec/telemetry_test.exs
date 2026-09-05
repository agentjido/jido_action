defmodule JidoActionTest.Exec.TelemetryTest do
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias Jido.Exec
  alias Jido.Exec.Telemetry
  alias Jido.Exec.Telemetry.Tracker
  alias Jido.Flow
  alias Jido.Flow.{Condition, Iterate, Reduce, Ref, Step}
  alias Jido.Flow.Map, as: FlowMap
  alias Jido.Instruction
  alias JidoActionTest.Fixtures.{BlockingFlow, MathFlow, TelemetryParentFlow}
  alias JidoActionTest.Fixtures.InlineControlledFlow
  alias JidoActionTest.Fixtures.Execution.BlockingAction
  alias JidoActionTest.Fixtures.Actions.{Add, ErrorAction}

  @flow_start [:jido, :flow, :start]
  @flow_stop [:jido, :flow, :stop]
  @flow_error [:jido, :flow, :error]
  @node_start [:jido, :flow, :node, :start]
  @node_stop [:jido, :flow, :node, :stop]
  @node_error [:jido, :flow, :node, :error]
  @target_start [:jido, :flow, :target, :start]
  @target_stop [:jido, :flow, :target, :stop]
  @target_error [:jido, :flow, :target, :error]
  @map_item_start [:jido, :flow, :map, :item, :start]
  @map_item_stop [:jido, :flow, :map, :item, :stop]
  @map_item_error [:jido, :flow, :map, :item, :error]
  @reduce_item_start [:jido, :flow, :reduce, :item, :start]
  @reduce_item_stop [:jido, :flow, :reduce, :item, :stop]
  @iterate_start [:jido, :flow, :iterate, :iteration, :start]
  @iterate_stop [:jido, :flow, :iterate, :iteration, :stop]
  @action_start [:jido, :action, :start]
  @action_stop [:jido, :action, :stop]
  @action_error [:jido, :action, :error]

  @flow_events [
    @flow_start,
    @flow_stop,
    @flow_error,
    @node_start,
    @node_stop,
    @node_error,
    @target_start,
    @target_stop,
    @target_error
  ]

  @collection_events [
    @map_item_start,
    @map_item_stop,
    @map_item_error,
    @reduce_item_start,
    @reduce_item_stop,
    @iterate_start,
    @iterate_stop
  ]

  test "emits one outer lifecycle for every executable target form" do
    attach([@action_start, @action_stop, @action_error, @flow_start, @flow_stop, @flow_error])

    action_instruction = Instruction.new!(target: Add, params: %{value: 2})
    flow_instruction = Instruction.new!(target: MathFlow, params: %{value: 2})

    forms = [
      action: {Add, %{value: 2}, [@action_start, @action_stop], :action, Add.name()},
      action_instruction:
        {action_instruction, %{}, [@action_start, @action_stop], :instruction, Add.name()},
      flow_value: {MathFlow.flow(), %{value: 2}, [@flow_start, @flow_stop], nil, "math_flow"},
      flow_module: {MathFlow, %{value: 2}, [@flow_start, @flow_stop], nil, "math_flow"},
      flow_instruction:
        {flow_instruction, %{}, [@action_start, @flow_start, @flow_stop, @action_stop],
         :instruction, "math_flow"}
    ]

    for {form, {target, input, expected_events, kind, name}} <- forms do
      assert {:ok, _result} = Exec.run(target, input), to_string(form)
      recorded = events()
      assert Enum.map(recorded, &elem(&1, 0)) == expected_events

      ids = Enum.map(recorded, fn {_event, _measurements, metadata} -> metadata.execution_id end)
      assert [_execution_id] = Enum.uniq(ids)

      for {event, measurements, metadata} <- recorded do
        if event in [@action_start, @action_stop] do
          assert metadata.kind == kind
          assert metadata.name == name
        else
          assert metadata.flow == name
        end

        if event in [@action_stop, @flow_stop], do: assert(measurements.duration >= 0)
      end
    end
  end

  test "emits Flow, component, and target lifecycles" do
    attach(@flow_events)
    flow = one_step_flow(Add)
    assert Exec.run(flow, %{value: 2}) == {:ok, %{value: 3}}

    assert [
             {@flow_start, _, flow_start},
             {@node_start, _, node_start},
             {@target_start, _, target_start},
             {@target_stop, _, target_stop},
             {@node_stop, node_measurements, node_stop},
             {@flow_stop, flow_measurements, flow_stop}
           ] = events()

    execution_id = flow_start.execution_id
    assert flow_start == %{execution_id: execution_id, flow: "native_telemetry_flow"}

    assert node_start == %{
             execution_id: execution_id,
             flow: "native_telemetry_flow",
             node: "add",
             kind: :step
           }

    assert node_stop == node_start
    assert target_stop == target_start
    assert target_start.target == Add
    assert target_start.option == nil
    assert flow_stop == flow_start
    assert node_measurements.duration >= 0
    assert flow_measurements.duration >= 0
  end

  test "emits component and Flow errors for a failed Action target" do
    attach(@flow_events)
    flow = one_step_flow(ErrorAction, %{error_type: :validation})
    assert {:error, error} = Exec.run(flow)

    assert [
             {@flow_start, _, flow_start},
             {@node_start, _, node_start},
             {@target_start, _, target_start},
             {@target_error, _, target_error},
             {@node_error, _, node_error},
             {@flow_error, _, flow_error}
           ] = events()

    assert target_error.error_type == :execution_error
    assert node_error.error == error
    assert flow_error.error == error
    assert Map.drop(target_error, [:error, :error_type]) == target_start
    assert Map.drop(node_error, [:error, :error_type]) == node_start
    assert Map.drop(flow_error, [:error, :error_type]) == flow_start
  end

  test "closes a direct Action lifecycle when the complete-call timeout wins" do
    attach([@action_start, @action_stop, @action_error])
    owner = self()

    task =
      Task.async(fn ->
        Exec.run(BlockingAction, %{value: 1}, %{test_pid: owner}, timeout: 100)
      end)

    assert_receive {:blocking_flow_node_started, worker}, 1_000
    assert {:error, timeout_error} = Task.await(task, 1_000)
    assert %Jido.Action.Error.TimeoutError{} = timeout_error

    assert [
             {@action_start, _, start_metadata},
             {@action_error, measurements, error_metadata}
           ] = events()

    assert Map.drop(error_metadata, [:error, :error_type]) == start_metadata
    assert error_metadata.error == timeout_error
    assert error_metadata.error_type == :timeout
    assert measurements.duration >= 0
    refute_received {@action_stop, _, _}
    refute Process.alive?(worker)
  end

  test "closes active Flow, node, and target lifecycles when timeout wins" do
    attach(@flow_events)

    flow = one_step_flow(BlockingAction, %{value: 1})
    owner = self()

    task =
      Task.async(fn ->
        Exec.run(flow, %{}, %{test_pid: owner}, timeout: 100)
      end)

    assert_receive {:blocking_flow_node_started, worker}, 1_000
    assert {:error, timeout_error} = Task.await(task, 1_000)
    assert %Jido.Flow.Error.TimeoutError{} = timeout_error

    assert [
             {@flow_start, _, flow_start},
             {@node_start, _, node_start},
             {@target_start, _, target_start},
             {@target_error, _, target_error},
             {@node_error, _, node_error},
             {@flow_error, _, flow_error}
           ] = events()

    assert target_error.error == timeout_error
    assert node_error.error == timeout_error
    assert flow_error.error == timeout_error
    assert Map.drop(target_error, [:error, :error_type]) == target_start
    assert Map.drop(node_error, [:error, :error_type]) == node_start
    assert Map.drop(flow_error, [:error, :error_type]) == flow_start
    refute Process.alive?(worker)
  end

  test "closes a direct Action lifecycle when asynchronous cancellation wins" do
    attach([@action_start, @action_stop, @action_error])
    handle = Exec.run_async(BlockingAction, %{value: 1}, %{test_pid: self()})

    assert_receive {:blocking_flow_node_started, worker}, 1_000
    assert :ok = Exec.cancel(handle)

    assert [
             {@action_start, _, start_metadata},
             {@action_error, _, error_metadata}
           ] = events()

    assert Map.drop(error_metadata, [:error, :error_type]) == start_metadata
    assert %Jido.Exec.Error.CancelledError{} = error_metadata.error
    assert error_metadata.error_type == :async_cancelled
    refute Process.alive?(worker)
  end

  test "closes active Flow lifecycles when asynchronous cancellation wins" do
    attach(@flow_events)
    handle = Exec.run_async(BlockingFlow, %{value: 1}, %{test_pid: self()})

    assert_receive {:blocking_flow_node_started, worker}, 1_000
    assert :ok = Exec.cancel(handle)

    assert [
             {@flow_start, _, flow_start},
             {@node_start, _, node_start},
             {@target_start, _, target_start},
             {@target_error, _, target_error},
             {@node_error, _, node_error},
             {@flow_error, _, flow_error}
           ] = events()

    assert %Jido.Exec.Error.CancelledError{} = flow_error.error
    assert target_error.error == flow_error.error
    assert node_error.error == flow_error.error
    assert Map.drop(target_error, [:error, :error_type]) == target_start
    assert Map.drop(node_error, [:error, :error_type]) == node_start
    assert Map.drop(flow_error, [:error, :error_type]) == flow_start
    refute Process.alive?(worker)
  end

  test "the finite-timeout tracker emits one terminal event per span" do
    attach([@action_start, @action_stop, @action_error])
    {:ok, tracker} = Jido.Exec.Telemetry.Tracker.start_link()

    Jido.Exec.Telemetry.with_tracker(tracker, fn ->
      span =
        Jido.Exec.Telemetry.start([:jido, :action], %{
          execution_id: "tracker-test",
          kind: :action,
          name: :tracker_test
        })

      assert Jido.Exec.Telemetry.stop(span) == :ok
      assert Jido.Exec.Telemetry.stop(span) == :ok
    end)

    assert Jido.Exec.Telemetry.Tracker.fail_all(tracker, :timeout) == :ok

    Jido.Exec.Telemetry.with_tracker(tracker, fn ->
      suppressed =
        Jido.Exec.Telemetry.start([:jido, :action], %{
          execution_id: "tracker-test",
          kind: :action,
          name: :suppressed
        })

      assert Jido.Exec.Telemetry.error(suppressed, :late) == :ok
    end)

    assert Jido.Exec.Telemetry.Tracker.stop(tracker) == :ok

    assert [
             {@action_start, _, %{name: :tracker_test}},
             {@action_stop, _, %{name: :tracker_test}}
           ] = events()
  end

  for form <- [:action, :flow], terminal <- [:cancel, :timeout] do
    @tag timeout: 10_000
    @tag inline_form: form, inline_terminal: terminal
    test "inline #{form} #{terminal} cleans up workers and closes each started lifecycle once", %{
      inline_form: form,
      inline_terminal: terminal
    } do
      attach([@action_start, @action_stop, @action_error] ++ @flow_events)
      token = make_ref()
      context = %{test_pid: self(), token: token}
      action = InlineControlledFlow.step_action("first")
      supervisor = __MODULE__.TaskSupervisor
      start_supervised!({Task.Supervisor, name: supervisor})

      {target, input, prefixes} =
        case form do
          :action ->
            {action, %{value: 1, ctx: context}, [[:jido, :action]]}

          :flow ->
            {InlineControlledFlow, %{first: 1, second: 2, third: 3},
             [[:jido, :flow], [:jido, :flow, :node], [:jido, :flow, :target]]}
        end

      opts = [max_concurrency: 1, task_supervisor: __MODULE__.TaskSupervisor]
      opts = if terminal == :timeout, do: Keyword.put(opts, :timeout, 2_000), else: opts
      handle = Exec.run_async(target, input, context, opts)
      caller_monitor = Process.monitor(handle.pid)

      try do
        assert_receive {:inline_started, ^token, value, worker}, 1_000
        worker_monitor = Process.monitor(worker)

        worker_action =
          InlineControlledFlow.step_action(Enum.at(["first", "second", "third"], value - 1))

        expected_error =
          case {terminal, form} do
            {:cancel, _form} ->
              assert :ok = Exec.cancel(handle)
              Jido.Exec.Error.CancelledError

            {:timeout, :action} ->
              assert {:error, %Jido.Action.Error.TimeoutError{timeout: 2_000}} =
                       Exec.await(handle, 5_000)

              Jido.Action.Error.TimeoutError

            {:timeout, :flow} ->
              assert {:error, %Jido.Flow.Error.TimeoutError{timeout: 2_000}} =
                       Exec.await(handle, 5_000)

              Jido.Flow.Error.TimeoutError
          end

        assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _reason}, 1_000
        assert_receive {:DOWN, ^caller_monitor, :process, _, _reason}, 1_000
        assert Task.Supervisor.children(supervisor) == []
        refute_received {:inline_started, ^token, _value, _worker}
        refute_received {:inline_finished, ^token, _value}

        recorded = events()
        assert length(recorded) == length(prefixes) * 2

        assert [_execution_id] =
                 recorded
                 |> Enum.map(fn {_event, _measurements, metadata} -> metadata.execution_id end)
                 |> Enum.uniq()

        for prefix <- prefixes do
          start_event = prefix ++ [:start]
          error_event = prefix ++ [:error]

          assert [
                   {^start_event, _, start_metadata},
                   {^error_event, measurements, error_metadata}
                 ] = Enum.filter(recorded, fn {event, _, _} -> Enum.drop(event, -1) == prefix end)

          assert error_metadata.error.__struct__ == expected_error

          expected_error_type =
            case {terminal, form} do
              {:cancel, _form} -> :async_cancelled
              {:timeout, :action} -> :timeout
              {:timeout, :flow} -> :flow_timeout
            end

          assert error_metadata.error_type == expected_error_type

          assert Map.drop(error_metadata, [:error, :error_type]) == start_metadata
          assert measurements.duration >= 0

          if prefix == [:jido, :flow, :target], do: assert(start_metadata.target == worker_action)
        end
      after
        Exec.cancel(handle)
        Process.demonitor(caller_monitor, [:flush])
      end
    end
  end

  test "tracker calls are safe after the tracker stops" do
    span =
      Telemetry.start([:jido, :action], %{
        execution_id: "stopped-tracker-test",
        kind: :action,
        name: :stopped_tracker
      })

    assert :ok = Telemetry.stop(span)
    {:ok, tracker} = Tracker.start_link()
    assert :ok = Tracker.stop(tracker)
    refute Process.alive?(tracker)

    assert :suppressed = Tracker.open(tracker, span)
    assert :ok = Tracker.close(tracker, span, :stop, %{})
    assert :ok = Tracker.fail_all(tracker, :late_failure)
    assert :ok = Tracker.stop(tracker)
  end

  test "classifies raw telemetry errors by value type" do
    for {error, expected_type} <- [
          {"error", :binary},
          {%{reason: :failed}, :map},
          {{:error, :failed}, :tuple},
          {[:error, :failed], :list},
          {1.5, :other}
        ] do
      assert %{error: ^error, error_type: ^expected_type} = Telemetry.error_metadata(error)
    end
  end

  test "keeps one lifecycle open across step-wise execution" do
    attach(@flow_events)

    flow =
      Flow.new!(
        name: "stepwise_telemetry",
        components: [
          Step.new!(name: "first", action: Add, params: %{value: Ref.input(:value)}),
          Step.new!(
            name: "second",
            action: Add,
            params: %{value: Ref.result("first", :value)}
          )
        ],
        output: Ref.result("second")
      )

    assert {:ok, execution} = Exec.start(flow, %{value: 1})
    assert [{@flow_start, _, start_metadata}] = events()

    assert {:ok, _runnable, execution} = Exec.step(execution)
    first_events = events()

    assert Enum.map(first_events, &elem(&1, 0)) ==
             [@node_start, @target_start, @target_stop, @node_stop]

    assert {:ok, _runnable, execution} = Exec.step(execution)
    assert Exec.result(execution) == {:ok, %{value: 3}}
    terminal_events = events()

    assert Enum.map(terminal_events, &elem(&1, 0)) ==
             [@node_start, @target_start, @target_stop, @node_stop, @flow_stop]

    ids =
      (first_events ++ terminal_events)
      |> Enum.map(fn {_event, _measurements, metadata} -> metadata.execution_id end)

    assert Enum.uniq(ids) == [start_metadata.execution_id]
  end

  test "does not add a child Flow lifecycle around native Subflow work" do
    attach(@flow_events)
    assert Exec.run(TelemetryParentFlow, %{value: 2}) == {:ok, %{value: 3}}
    recorded = events()

    assert Enum.count(recorded, &(elem(&1, 0) == @flow_start)) == 1
    assert Enum.count(recorded, &(elem(&1, 0) == @flow_stop)) == 1

    node_names =
      for {@node_start, _measurements, metadata} <- recorded,
          do: metadata.node

    assert node_names == ["child"]

    assert recorded
           |> Enum.map(fn {_event, _measurements, metadata} -> metadata.execution_id end)
           |> Enum.uniq()
           |> length() == 1
  end

  test "emits Map, Reduce, and Iterate work-unit lifecycles" do
    attach(@collection_events)

    flow =
      Flow.new!(
        name: "collection_telemetry",
        components: [
          FlowMap.new!(
            name: "mapped",
            collection: [1, 2],
            action: Add,
            params: %{value: Ref.item(), amount: 1}
          ),
          Reduce.new!(
            name: "total",
            collection: Ref.result("mapped"),
            initial: %{value: 0},
            action: Add,
            params: %{value: Ref.accumulator(:value), amount: Ref.item(:value)}
          ),
          Iterate.new!(
            name: "count",
            action: Add,
            params: %{value: Ref.state(:value), amount: 1},
            state: [
              schema: [],
              initial: %{value: Ref.result("total", :value)},
              update: Ref.body_result()
            ],
            completion: Condition.gte(Ref.state(:value), 7),
            max_iterations: 2
          )
        ],
        output: Ref.result("count")
      )

    assert {:ok, %{iterations: 2, state: %{value: 7}}} =
             Exec.run(flow, %{}, %{}, max_concurrency: 1)

    recorded = events()

    assert Enum.map(recorded, &elem(&1, 0)) == [
             @map_item_start,
             @map_item_stop,
             @map_item_start,
             @map_item_stop,
             @reduce_item_start,
             @reduce_item_stop,
             @reduce_item_start,
             @reduce_item_stop,
             @iterate_start,
             @iterate_stop,
             @iterate_start,
             @iterate_stop
           ]

    ids = Enum.map(recorded, fn {_event, _measurements, metadata} -> metadata.execution_id end)
    assert length(Enum.uniq(ids)) == 1
  end

  test "emits a Map item error for a collected failure" do
    attach(@collection_events)

    flow =
      Flow.new!(
        name: "map_error_telemetry",
        components: [
          FlowMap.new!(
            name: "mapped",
            collection: [:one],
            action: ErrorAction,
            params: %{error_type: :validation},
            on_error: :collect_errors
          )
        ],
        output: %{items: Ref.result("mapped")}
      )

    assert {:ok, %{items: [%{status: :error}]}} = Exec.run(flow)

    assert [
             {@map_item_start, _, start_metadata},
             {@map_item_error, measurements, error_metadata}
           ] = events()

    assert Map.drop(error_metadata, [:error, :error_type]) == start_metadata
    assert error_metadata.error_type == :execution_error
    assert measurements.duration >= 0
  end

  defp one_step_flow(action, params \\ %{value: Ref.input(:value)}) do
    Flow.new!(
      name: "native_telemetry_flow",
      components: [Step.new!(name: "add", action: action, params: params)],
      output: Ref.result("add")
    )
  end

  defp attach(event_names) do
    test_pid = self()
    handler_id = "native-telemetry-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        event_names,
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp events, do: receive_events([])

  defp receive_events(events) do
    receive do
      {:telemetry_event, event, measurements, metadata} ->
        receive_events([{event, measurements, metadata} | events])
    after
      0 -> Enum.reverse(events)
    end
  end
end
