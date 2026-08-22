defmodule Jido.Exec.TelemetryTest do
  use JidoTest.ActionCase, async: false
  @moduletag capture_log: true

  alias Jido.Exec
  alias Jido.Flow
  alias Jido.Flow.{Node, Ref}
  alias JidoTest.TestActions.{Add, ErrorAction}

  @exec_start [:jido, :exec, :start]
  @exec_stop [:jido, :exec, :stop]
  @exec_error [:jido, :exec, :error]
  @flow_start [:jido, :flow, :start]
  @flow_stop [:jido, :flow, :stop]
  @flow_error [:jido, :flow, :error]
  @node_start [:jido, :flow, :node, :start]
  @node_stop [:jido, :flow, :node, :stop]
  @node_error [:jido, :flow, :node, :error]

  @public_events [
    @exec_start,
    @exec_stop,
    @exec_error,
    @flow_start,
    @flow_stop,
    @flow_error,
    @node_start,
    @node_stop,
    @node_error
  ]

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

  test "emits the exact Exec lifecycle for an Action" do
    attach(@public_events)

    assert {:ok, %{value: 6}} = Exec.run(Add, %{value: 5})

    assert [
             {@exec_start, start_measurements, start_metadata},
             {@exec_stop, stop_measurements, stop_metadata}
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

  test "nests one Flow lifecycle and one node lifecycle under Exec" do
    attach(@public_events)
    flow = one_node_flow(Add)

    assert {:ok, %{value: 3}} = Exec.run(flow, %{value: 2})

    assert [
             {@exec_start, _, exec_start},
             {@flow_start, _, flow_start},
             {@node_start, _, node_start},
             {@node_stop, node_stop_measurements, node_stop},
             {@flow_stop, flow_stop_measurements, flow_stop},
             {@exec_stop, exec_stop_measurements, exec_stop}
           ] = events()

    execution_id = exec_start.execution_id
    assert flow_start == %{execution_id: execution_id, flow: "telemetry_flow"}

    assert node_start == %{
             execution_id: execution_id,
             flow: "telemetry_flow",
             node: "add",
             kind: :step
           }

    assert node_stop == node_start
    assert flow_stop == flow_start
    assert exec_stop == exec_start

    for measurements <- [node_stop_measurements, flow_stop_measurements, exec_stop_measurements] do
      assert Map.keys(measurements) |> Enum.sort() == [:duration, :monotonic_time]
      assert measurements.duration >= 0
    end
  end

  test "keeps one correlation identifier across a nested Flow" do
    child = unique_module("TelemetryChildFlow")

    create_module(
      child,
      quote do
        use Jido.Flow, name: "telemetry_child_flow"

        flow do
          step("child_add", action: unquote(Add), params: %{value: input(:value)})
        end
      end
    )

    parent = unique_module("TelemetryParentFlow")

    create_module(
      parent,
      quote do
        use Jido.Flow, name: "telemetry_parent_flow"

        flow do
          step("child", action: unquote(child), params: %{value: input(:value)})
        end
      end
    )

    attach(@public_events)
    assert {:ok, %{value: 3}} = Exec.run(parent, %{value: 2})

    recorded = events()

    assert [
             @exec_start,
             @flow_start,
             @node_start,
             @exec_start,
             @flow_start,
             @node_start,
             @node_stop,
             @flow_stop,
             @exec_stop,
             @node_stop,
             @flow_stop,
             @exec_stop
           ] == Enum.map(recorded, &elem(&1, 0))

    execution_ids =
      Enum.map(recorded, fn {_event, _measurements, metadata} -> metadata.execution_id end)

    assert [_execution_id] = Enum.uniq(execution_ids)
  end

  test "uses error events for returned execution failures" do
    attach(@public_events)
    flow = one_node_flow(ErrorAction, %{error_type: Ref.value(:validation)})

    assert {:error, error} = Exec.run(flow)

    assert [
             {@exec_start, _, exec_start},
             {@flow_start, _, flow_start},
             {@node_start, _, node_start},
             {@node_error, node_measurements, node_error},
             {@flow_error, flow_measurements, flow_error},
             {@exec_error, exec_measurements, exec_error}
           ] = events()

    assert node_error.execution_id == exec_start.execution_id
    assert flow_error.execution_id == exec_start.execution_id
    assert exec_error.execution_id == exec_start.execution_id
    assert node_error.error == error
    assert flow_error.error == error
    assert exec_error.error == error
    assert node_error.error_type == :execution_error

    assert Map.drop(node_error, [:error, :error_type]) == node_start
    assert Map.drop(flow_error, [:error, :error_type]) == flow_start
    assert Map.drop(exec_error, [:error, :error_type]) == exec_start

    for measurements <- [node_measurements, flow_measurements, exec_measurements] do
      assert Map.keys(measurements) |> Enum.sort() == [:duration, :monotonic_time]
    end
  end

  test "closes Exec and Flow lifecycles when an input schema effect raises" do
    attach(@public_events)

    flow =
      Flow.new!(
        name: "raising_schema",
        schema: Zoi.map() |> Zoi.transform({__MODULE__, :raise_flow_transform, []}),
        nodes: [Node.new!(name: "add", action: Add)],
        return: Ref.result("add")
      )

    assert {:error, error} = Exec.run(flow)

    assert [
             {@exec_start, _, exec_start},
             {@flow_start, _, flow_start},
             {@flow_error, _, flow_error},
             {@exec_error, _, exec_error}
           ] = events()

    assert flow_error.execution_id == exec_start.execution_id
    assert exec_error.execution_id == exec_start.execution_id
    assert flow_error.error == error
    assert exec_error.error == error
    assert Map.drop(flow_error, [:error, :error_type]) == flow_start
  end

  test "emits a node error when an asynchronous node task is killed" do
    attach(@public_events)
    flow = one_node_flow(KillAction, %{})

    assert {:error, error} = Exec.run(flow, %{}, %{}, async: true)

    assert [
             {@exec_start, _, exec_start},
             {@flow_start, _, _flow_start},
             {@node_start, _, node_start},
             {@node_error, _, node_error},
             {@flow_error, _, _flow_error},
             {@exec_error, _, _exec_error}
           ] = events()

    assert node_error.execution_id == exec_start.execution_id
    assert node_error.error == error
    assert Map.drop(node_error, [:error, :error_type]) == node_start
  end

  test "reports final result-path errors after the node span stops" do
    attach(@public_events)

    flow =
      Flow.new!(
        name: "missing_result_path",
        nodes: [Node.new!(name: "list", action: ListOutputAction)],
        return: Ref.result("list", [:items, 99])
      )

    assert {:error, error} = Exec.run(flow)

    assert [
             {@exec_start, _, exec_start},
             {@flow_start, _, _flow_start},
             {@node_start, _, node_start},
             {@node_stop, _, node_stop},
             {@flow_error, _, flow_error},
             {@exec_error, _, exec_error}
           ] = events()

    assert node_stop == node_start
    assert flow_error.execution_id == exec_start.execution_id
    assert exec_error.execution_id == exec_start.execution_id
    assert flow_error.error == error
    assert exec_error.error == error
  end

  test "step-wise execution closes lifecycle events only at a terminal step" do
    attach(@public_events)

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
    assert [@exec_start, @flow_start] == Enum.map(start_events, &elem(&1, 0))

    assert {:ok, _node_result, execution} = Exec.step(execution)
    first_events = events()
    assert [@node_start, @node_stop] == Enum.map(first_events, &elem(&1, 0))

    assert {:ok, _node_result, execution} = Exec.step(execution)
    assert {:ok, %{value: 3}} = Exec.result(execution)

    terminal_events = events()

    assert [
             @node_start,
             @node_stop,
             @flow_stop,
             @exec_stop
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
