defmodule Jido.Exec.TelemetryTest do
  use JidoTest.ActionCase, async: false
  @moduletag capture_log: true

  alias Jido.Action.Telemetry
  alias Jido.Exec
  alias Jido.Flow
  alias Jido.Flow.{Node, Ref}
  alias Jido.Instruction
  alias JidoTest.ExecFixtures.{InstructionTelemetryFlow, TelemetryParentFlow}
  alias JidoTest.TestActions.{Add, ErrorAction, StacktraceAction}

  @action_start [:jido, :action, :start]
  @action_stop [:jido, :action, :stop]
  @action_error [:jido, :action, :error]
  @flow_start [:jido, :flow, :start]
  @flow_stop [:jido, :flow, :stop]
  @flow_error [:jido, :flow, :error]
  @node_start [:jido, :flow, :node, :start]
  @node_stop [:jido, :flow, :node, :stop]
  @node_error [:jido, :flow, :node, :error]

  @public_events [
    @action_start,
    @action_stop,
    @action_error,
    @flow_start,
    @flow_stop,
    @flow_error,
    @node_start,
    @node_stop,
    @node_error
  ]

  @retired_exec_events [
    [:jido, :exec, :start],
    [:jido, :exec, :stop],
    [:jido, :exec, :error]
  ]

  @observed_events @public_events ++ @retired_exec_events

  def raise_flow_transform(_value, _opts), do: raise("flow schema boom")

  defmodule KillAction do
    @moduledoc false
    use Jido.Action, name: "kill_telemetry_task"

    @impl true
    def run(_params, _context), do: Process.exit(self(), :kill)
  end

  defmodule ListOutputAction do
    @moduledoc false
    use Jido.Action, name: "telemetry_list_output"

    @impl true
    def run(_params, _context), do: {:ok, %{items: [%{value: 1}]}}
  end

  test "emits the exact Action lifecycle for an Action" do
    attach(@observed_events)

    assert {:ok, %{value: 6}} = Exec.run(Add, %{value: 5})

    assert [
             {@action_start, start_measurements, start_metadata},
             {@action_stop, stop_measurements, stop_metadata}
           ] = events()

    assert Map.keys(start_measurements) |> Enum.sort() == [:monotonic_time, :system_time]
    assert Map.keys(stop_measurements) |> Enum.sort() == [:duration, :monotonic_time]
    assert stop_measurements.duration >= 0
    assert start_metadata == stop_metadata
    assert Map.keys(start_metadata) |> Enum.sort() == [:execution_id, :kind, :name]
    assert start_metadata.kind == :action
    assert start_metadata.name == "add_one"
    assert is_binary(start_metadata.execution_id)
  end

  test "emits the Action lifecycle for an Instruction" do
    attach(@observed_events)
    instruction = Instruction.new!(action: Add, params: %{value: 5})

    assert {:ok, %{value: 6}} = Exec.run(instruction)

    assert [
             {@action_start, _, start_metadata},
             {@action_stop, _, stop_metadata}
           ] = events()

    assert start_metadata == stop_metadata
    assert start_metadata.kind == :instruction
    assert start_metadata.name == "add_one"
    assert is_binary(start_metadata.execution_id)
  end

  test "nests a Flow lifecycle inside an Instruction Action lifecycle" do
    attach(@observed_events)
    instruction = Instruction.new!(action: InstructionTelemetryFlow, params: %{value: 2})

    assert {:ok, %{value: 3}} = Exec.run(instruction)

    recorded = events()

    assert [
             @action_start,
             @flow_start,
             @node_start,
             @node_stop,
             @flow_stop,
             @action_stop
           ] == Enum.map(recorded, &elem(&1, 0))

    execution_ids =
      Enum.map(recorded, fn {_event, _measurements, metadata} -> metadata.execution_id end)

    assert [_execution_id] = Enum.uniq(execution_ids)
  end

  test "uses the Action error event for a returned Action failure" do
    attach(@observed_events)

    assert {:error, error} = Exec.run(ErrorAction, %{error_type: :validation})

    assert [
             {@action_start, _, start_metadata},
             {@action_error, measurements, error_metadata}
           ] = events()

    assert Map.drop(error_metadata, [:error, :error_type]) == start_metadata
    assert error_metadata.error == error
    assert error_metadata.error_type == :execution_error
    assert Map.keys(measurements) |> Enum.sort() == [:duration, :monotonic_time]
  end

  test "includes the caught Action stacktrace in error telemetry" do
    attach([@action_error])

    assert {:error, error} = Exec.run(StacktraceAction, %{mode: :raise})
    assert [{@action_error, _measurements, %{error: ^error}}] = events()
    assert %Splode.Stacktrace{stacktrace: stacktrace} = error.stacktrace

    assert Enum.any?(stacktrace, fn
             {StacktraceAction, :raise_from_action, 0, _location} -> true
             _frame -> false
           end)
  end

  test "emits only the Flow and node lifecycles for a Flow" do
    attach(@observed_events)
    flow = one_node_flow(Add)

    assert {:ok, %{value: 3}} = Exec.run(flow, %{value: 2})

    assert [
             {@flow_start, _, flow_start},
             {@node_start, _, node_start},
             {@node_stop, node_stop_measurements, node_stop},
             {@flow_stop, flow_stop_measurements, flow_stop}
           ] = events()

    execution_id = flow_start.execution_id
    assert flow_start == %{execution_id: execution_id, flow: "telemetry_flow"}

    assert node_start == %{
             execution_id: execution_id,
             flow: "telemetry_flow",
             node: "add",
             kind: :step
           }

    assert node_stop == node_start
    assert flow_stop == flow_start

    for measurements <- [node_stop_measurements, flow_stop_measurements] do
      assert Map.keys(measurements) |> Enum.sort() == [:duration, :monotonic_time]
      assert measurements.duration >= 0
    end
  end

  test "keeps one correlation identifier across a nested Flow" do
    attach(@observed_events)
    assert {:ok, %{value: 3}} = Exec.run(TelemetryParentFlow, %{value: 2})

    recorded = events()

    assert [
             @flow_start,
             @node_start,
             @flow_start,
             @node_start,
             @node_stop,
             @flow_stop,
             @node_stop,
             @flow_stop
           ] == Enum.map(recorded, &elem(&1, 0))

    execution_ids =
      Enum.map(recorded, fn {_event, _measurements, metadata} -> metadata.execution_id end)

    assert [_execution_id] = Enum.uniq(execution_ids)
  end

  test "uses error events for returned execution failures" do
    attach(@observed_events)
    flow = one_node_flow(ErrorAction, %{error_type: Ref.value(:validation)})

    assert {:error, error} = Exec.run(flow)

    assert [
             {@flow_start, _, flow_start},
             {@node_start, _, node_start},
             {@node_error, node_measurements, node_error},
             {@flow_error, flow_measurements, flow_error}
           ] = events()

    assert node_error.execution_id == flow_start.execution_id
    assert flow_error.execution_id == flow_start.execution_id
    assert node_error.error == error
    assert flow_error.error == error
    assert node_error.error_type == :execution_error

    assert Map.drop(node_error, [:error, :error_type]) == node_start
    assert Map.drop(flow_error, [:error, :error_type]) == flow_start

    for measurements <- [node_measurements, flow_measurements] do
      assert Map.keys(measurements) |> Enum.sort() == [:duration, :monotonic_time]
    end
  end

  test "closes the Flow lifecycle when an input schema effect raises" do
    attach(@observed_events)

    flow =
      Flow.new!(
        name: "raising_schema",
        schema: Zoi.map() |> Zoi.transform({__MODULE__, :raise_flow_transform, []}),
        nodes: [Node.new!(name: "add", action: Add)],
        return: Ref.result("add")
      )

    assert {:error, error} = Exec.run(flow)

    assert [
             {@flow_start, _, flow_start},
             {@flow_error, _, flow_error}
           ] = events()

    assert flow_error.execution_id == flow_start.execution_id
    assert flow_error.error == error
    assert Map.drop(flow_error, [:error, :error_type]) == flow_start
  end

  test "emits a node error when an asynchronous node task is killed" do
    attach(@observed_events)
    flow = one_node_flow(KillAction, %{})

    assert {:error, error} = Exec.run(flow, %{}, %{}, async: true)

    assert [
             {@flow_start, _, flow_start},
             {@node_start, _, node_start},
             {@node_error, _, node_error},
             {@flow_error, _, _flow_error}
           ] = events()

    assert node_error.execution_id == flow_start.execution_id
    assert node_error.error == error
    assert Map.drop(node_error, [:error, :error_type]) == node_start
  end

  test "orders asynchronous node spans by the canonical ready set" do
    attach(@observed_events)

    flow =
      Flow.new!(
        name: "async_telemetry_order",
        nodes: [
          Node.new!(name: "zeta", action: Add, input: %{value: Ref.input(:value)}),
          Node.new!(name: "alpha", action: Add, input: %{value: Ref.input(:value)})
        ],
        return: %{alpha: Ref.result("alpha"), zeta: Ref.result("zeta")}
      )

    assert {:ok, execution} = Exec.start(flow, %{value: 1}, %{}, async: true)

    assert [
             {@flow_start, _, %{execution_id: execution_id}}
           ] = events()

    assert {:ok, _results, execution} = Exec.wave(execution)
    assert {:ok, %{alpha: %{value: 2}, zeta: %{value: 2}}} = Exec.result(execution)

    assert [
             {@node_start, _, alpha_start},
             {@node_start, _, zeta_start},
             {@node_stop, _, alpha_stop},
             {@node_stop, _, zeta_stop},
             {@flow_stop, _, flow_stop}
           ] = events()

    assert alpha_start == %{
             execution_id: execution_id,
             flow: "async_telemetry_order",
             node: "alpha",
             kind: :step
           }

    assert zeta_start == %{alpha_start | node: "zeta"}
    assert alpha_stop == alpha_start
    assert zeta_stop == zeta_start
    assert flow_stop == %{execution_id: execution_id, flow: "async_telemetry_order"}
  end

  test "reports final result-path errors after the node span stops" do
    attach(@observed_events)

    flow =
      Flow.new!(
        name: "missing_result_path",
        nodes: [Node.new!(name: "list", action: ListOutputAction)],
        return: Ref.result("list", [:items, 99])
      )

    assert {:error, error} = Exec.run(flow)

    assert [
             {@flow_start, _, flow_start},
             {@node_start, _, node_start},
             {@node_stop, _, node_stop},
             {@flow_error, _, flow_error}
           ] = events()

    assert node_stop == node_start
    assert flow_error.execution_id == flow_start.execution_id
    assert flow_error.error == error
  end

  test "step-wise execution closes lifecycle events only at a terminal step" do
    attach(@observed_events)

    flow =
      Flow.new!(
        name: "stepwise_telemetry",
        nodes: [
          Node.new!(name: "first", action: Add, input: %{value: Ref.input(:value)}),
          Node.new!(name: "second", action: Add, input: %{value: Ref.result("first", :value)})
        ],
        return: Ref.result("second")
      )

    assert {:ok, execution} = Exec.start(flow, %{value: 1})
    start_events = events()
    assert [@flow_start] == Enum.map(start_events, &elem(&1, 0))

    assert {:ok, _node_result, execution} = Exec.step(execution)
    first_events = events()
    assert [@node_start, @node_stop] == Enum.map(first_events, &elem(&1, 0))

    assert {:ok, _node_result, execution} = Exec.step(execution)
    assert {:ok, %{value: 3}} = Exec.result(execution)

    terminal_events = events()

    assert [
             @node_start,
             @node_stop,
             @flow_stop
           ] == Enum.map(terminal_events, &elem(&1, 0))

    execution_ids =
      (start_events ++ first_events ++ terminal_events)
      |> Enum.map(fn {_event, _measurements, metadata} -> metadata.execution_id end)

    assert length(Enum.uniq(execution_ids)) == 1
  end

  test "does not emit internal Map, Reduce, Iterator, or state events" do
    internal_events = [
      [:jido, :flow, :map, :item, :start],
      [:jido, :flow, :map, :item, :stop],
      [:jido, :flow, :reduce, :item, :start],
      [:jido, :flow, :reduce, :item, :stop],
      [:jido, :flow, :iterate, :start],
      [:jido, :flow, :iterate, :iteration, :start],
      [:jido, :flow, :iterate, :iteration, :stop],
      [:jido, :flow, :iterate, :state_transition],
      [:jido, :flow, :iterate, :completion],
      [:jido, :flow, :iterate, :exhaustion],
      [:jido, :flow, :iterate, :failure]
    ]

    attach(internal_events)
    assert {:ok, %{value: 2}} = Exec.run(one_node_flow(Add), %{value: 1})
    assert events() == []
  end

  test "classifies non-exception telemetry errors without changing them" do
    attach([@action_error])

    values = [
      {:atom, :atom},
      {"binary", :binary},
      {%{map: true}, :map},
      {{:tuple}, :tuple},
      {[:list], :list},
      {self(), :other}
    ]

    for {value, expected_type} <- values do
      span = %{event: [:jido, :action], metadata: %{}, started_at: System.monotonic_time()}
      assert :ok = Telemetry.error(span, value)
      assert [{@action_error, _measurements, metadata}] = events()
      assert metadata.error == value
      assert metadata.error_type == expected_type
    end
  end

  defp one_node_flow(action, input \\ %{value: Ref.input(:value)}) do
    Flow.new!(
      name: "telemetry_flow",
      nodes: [Node.new!(name: "add", action: action, input: input)],
      return: Ref.result("add")
    )
  end

  defp attach(event_names) do
    test_pid = self()
    handler_id = "telemetry-test-#{System.unique_integer([:positive])}"

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
