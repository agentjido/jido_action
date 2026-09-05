defmodule JidoActionTest.Exec.WorkInspectionTest do
  use ExUnit.Case, async: true

  alias Jido.{Exec, Flow}
  alias Jido.Exec.Work
  alias Jido.Flow.{Ref, Step, Subflow}
  alias Jido.Flow.Map, as: FlowMap
  alias Jido.Flow.Error.InvalidExecutionError
  alias JidoActionTest.Fixtures.Actions.{EchoParamsAction, ErrorAction, RecorderAction}
  alias JidoActionTest.Fixtures.MathFlow

  test "ready work is small, stable within a revision, and has an authored path" do
    assert {:ok, execution} = Exec.start(MathFlow, %{value: 3})
    assert [work] = Exec.ready(execution)
    assert work.__struct__ == Work
    assert work.component_path == ["add_one"]
    assert work.kind == :step
    assert work.role == :execute
    assert work.item_index == nil
    assert work.status == :ready
    assert Exec.ready(execution) == [work]

    assert Enum.sort(Map.keys(Map.from_struct(work))) ==
             [:component_path, :item_index, :kind, :role, :status, :token]

    assert {:ok, completed, next} = Exec.step(execution, work.token)
    assert completed == %{work | status: :completed}
    assert next.revision == execution.revision + 1
    assert [second] = Exec.ready(next)
    assert second.component_path == ["double"]
    assert second.token != work.token
    assert {:ok, _, next} = Exec.step(next)
    assert Exec.ready(next) == []
    assert Exec.result(next) == {:ok, %{value: 8}}
  end

  test "invalid and foreign selections do not consume work or the revision" do
    flow = recorder_flow()
    assert {:ok, execution} = Exec.start(flow, %{}, %{test_pid: self()})
    assert {:ok, other} = Exec.start(flow)
    ready = Exec.ready(execution)
    [work | _] = ready
    [foreign | _] = Exec.ready(other)
    [native | _] = Exec.native(execution).ready

    for token <- [foreign.token, make_ref(), nil, -1, :bad, %{}, work, native, native.id] do
      assert {:error, %InvalidExecutionError{details: %{reason: :invalid_work_token}} = error} =
               Exec.step(execution, token)

      assert is_binary(JSON.encode!(error))
      assert Exec.ready(execution) == ready
      assert execution.revision == 0
      refute_received {RecorderAction, _}
    end

    assert {:ok, _, current} = Exec.step(execution, work.token)
    assert_received {RecorderAction, %{value: "a"}}
    assert {:ok, _} = Exec.continue(current)
    assert {:ok, _} = Exec.continue(other)
  end

  test "a mutation invalidates all prior tokens, including still-ready work" do
    assert {:ok, execution} = Exec.start(recorder_flow(), %{}, %{test_pid: self()})
    [first, second] = Exec.ready(execution)
    assert {:ok, completed, current} = Exec.step(execution, first.token)
    assert completed.token == first.token
    assert_received {RecorderAction, %{value: "a"}}

    assert [remaining] = Exec.ready(current)
    assert remaining.component_path == second.component_path
    assert remaining.token != second.token

    for token <- [first.token, second.token] do
      assert {:error, %InvalidExecutionError{details: %{reason: :invalid_work_token}}} =
               Exec.step(current, token)
    end

    assert {:error, %InvalidExecutionError{details: %{reason: :stale_revision}}} =
             Exec.step(execution, second.token)

    assert {:error, %InvalidExecutionError{}} = Exec.step(execution, remaining.token)
    refute_received {RecorderAction, _}
    assert {:ok, _, finished} = Exec.step(current, remaining.token)
    assert_received {RecorderAction, %{value: "b"}}
    assert Exec.result(finished) == {:ok, %{a: %{value: "a"}, b: %{value: "b"}}}
  end

  test "a wave keeps the input tokens and ready order" do
    assert {:ok, execution} = Exec.start(recorder_flow())
    ready = Exec.ready(execution)
    assert {:ok, completed, finished} = Exec.wave(execution)
    assert completed == Enum.map(ready, &%{&1 | status: :completed})
    assert finished.revision == 1
    assert Exec.ready(finished) == []
  end

  test "current work tokens can move to another process" do
    assert {:ok, execution} = Exec.start(MathFlow, %{value: 3})
    [work] = Exec.ready(execution)
    task = Task.async(fn -> Exec.step(execution, work.token) end)
    assert {:ok, completed, current} = Task.await(task)
    assert completed == %{work | status: :completed}
    assert {:ok, finished} = Exec.continue(current)
    assert Exec.result(finished) == {:ok, %{value: 8}}
  end

  test "tokens do not require the process that created the paused execution" do
    owner = self()
    ref = make_ref()

    {creator, monitor} =
      spawn_monitor(fn ->
        {:ok, execution} = Exec.start(MathFlow, %{value: 3})
        [work] = Exec.ready(execution)
        send(owner, {ref, execution, work.token})
      end)

    assert_receive {^ref, execution, token}
    assert_receive {:DOWN, ^monitor, :process, ^creator, :normal}
    assert {:ok, _, current} = Exec.step(execution, token)
    assert {:ok, finished} = Exec.continue(current)
    assert Exec.result(finished) == {:ok, %{value: 8}}
  end

  test "concurrent token use is rejected while the original operation owns the guard" do
    flow =
      Flow.new!(
        name: "concurrent_token",
        components: [
          Step.new!(name: "block", action: JidoActionTest.Fixtures.Execution.BlockingAction)
        ],
        output: Ref.result("block")
      )

    assert {:ok, execution} = Exec.start(flow, %{}, %{test_pid: self()})
    [work] = Exec.ready(execution)
    task = Task.async(fn -> Exec.step(execution, work.token) end)

    try do
      assert_receive {:blocking_flow_node_started, worker}, 1_000
      monitor = Process.monitor(worker)

      assert {:error, %InvalidExecutionError{details: %{reason: :operation_in_progress}}} =
               Exec.step(execution, work.token)

      refute_received {:blocking_flow_node_started, _}
      send(worker, :finish)
      assert {:ok, completed, finished} = Task.await(task)
      assert completed == %{work | status: :completed}
      assert Exec.result(finished) == {:ok, %{}}
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 1_000
    after
      Task.shutdown(task, :brutal_kill)
    end
  end

  test "failed work reports status without retaining errors or payloads" do
    flow =
      Flow.new!(
        name: "failed_work",
        components: [
          Step.new!(name: "fail", action: ErrorAction, params: %{error_type: :validation})
        ],
        output: Ref.result("fail")
      )

    assert {:ok, execution} = Exec.start(flow)
    [work] = Exec.ready(execution)
    assert {:ok, failed, finished} = Exec.step(execution, work.token)
    assert failed == %{work | status: :failed}
    assert {:error, %Jido.Action.Error.ExecutionFailureError{}} = Exec.result(finished)
    assert Exec.ready(finished) == []
  end

  test "Map exposes each item and support unit without changing its result" do
    assert {:ok, execution} = Exec.start(map_flow(), %{items: [:same, :same]})
    {work, finished} = collect(execution)
    items = Enum.filter(work, &(&1.role == :map_item))
    assert Enum.sort(Enum.map(items, & &1.item_index)) == [0, 1]
    assert length(Enum.uniq_by(items, & &1.token)) == 2
    assert Enum.all?(work, &(&1.component_path == ["mapped"] and &1.kind == :map))

    assert Enum.uniq(Enum.map(work, & &1.role)) |> Enum.sort() ==
             [:fan_in, :fan_out, :input, :map_item, :output]

    assert Exec.result(finished) == {:ok, %{items: [%{value: :same}, %{value: :same}]}}
  end

  test "an empty Map retains its native support step" do
    assert {:ok, execution} = Exec.start(map_flow(), %{items: []})
    {work, finished} = collect(execution)
    assert Enum.any?(work, &(&1.role == :map_empty and is_nil(&1.item_index)))
    refute Enum.any?(work, &(&1.role == :map_item))
    assert Exec.result(finished) == {:ok, %{items: []}}
  end

  test "Map item failures distinguish failed work from collected error data" do
    for mode <- [:fail_fast, :collect_errors] do
      flow =
        Flow.new!(
          name: "map_item_errors",
          components: [
            FlowMap.new!(
              name: "mapped",
              collection: [1, 2],
              action: ErrorAction,
              params: %{error_type: :validation},
              on_error: mode
            )
          ],
          output: %{items: Ref.result("mapped")}
        )

      assert {:ok, execution} = Exec.start(flow)
      {work, finished} = collect(execution)
      items = Enum.filter(work, &(&1.role == :map_item))

      case mode do
        :fail_fast ->
          assert [failed] = items
          assert failed.status == :failed
          assert {:error, _} = Exec.result(finished)

        :collect_errors ->
          assert length(items) == 2
          assert Enum.all?(items, &(&1.status == :completed))
          assert {:ok, %{items: [%{status: :error}, %{status: :error}]}} = Exec.result(finished)
      end
    end
  end

  test "repeated Subflows retain complete paths and input binding support" do
    flow =
      Flow.new!(
        name: "repeated_children",
        components:
          Enum.map(
            ["left/part", "right"],
            &Subflow.new!(name: &1, flow: MathFlow, params: %{value: 3})
          ),
        output: %{left: Ref.result("left/part"), right: Ref.result("right")}
      )

    assert {:ok, execution} = Exec.start(flow)
    {work, finished} = collect(execution)

    for name <- ["left/part", "right"] do
      assert Enum.any?(work, &(&1.component_path == [name, "add_one"] and &1.role == :execute))
      assert Enum.any?(work, &(&1.component_path == [name, "double"] and &1.role == :execute))
      assert Enum.any?(work, &(&1.component_path == [name] and &1.role == :input_binding))
    end

    assert Exec.result(finished) == {:ok, %{left: %{value: 8}, right: %{value: 8}}}
  end

  test "Join activations remain separate selectable work units" do
    flow =
      Flow.new!(
        name: "joined_work",
        components: [
          Step.new!(name: "a", action: EchoParamsAction),
          Step.new!(name: "b", action: EchoParamsAction),
          Step.new!(name: "joined", action: EchoParamsAction, after: ["a", "b"])
        ],
        output: Ref.result("joined")
      )

    assert {:ok, execution} = Exec.start(flow)
    {work, finished} = collect(execution)
    joins = Enum.filter(work, &(&1.role == :join))
    assert joins != []
    assert length(Enum.uniq_by(joins, & &1.token)) == length(joins)
    assert Enum.all?(joins, &(&1.component_path == ["joined"]))
    assert Exec.result(finished) == {:ok, %{}}
  end

  test "shared Join support has no single authored owner" do
    flow =
      Flow.new!(
        name: "shared_join",
        components: [
          Step.new!(name: "a", action: EchoParamsAction),
          Step.new!(name: "b", action: EchoParamsAction),
          Step.new!(name: "left", action: EchoParamsAction, after: ["a", "b"]),
          Step.new!(name: "right", action: EchoParamsAction, after: ["a", "b"])
        ],
        output: %{left: Ref.result("left"), right: Ref.result("right")}
      )

    assert {:ok, execution} = Exec.start(flow)
    {work, finished} = collect(execution)
    joins = Enum.filter(work, &(&1.role == :join))
    assert joins != []
    assert Enum.all?(joins, &(&1.kind == :support and is_nil(&1.component_path)))
    assert Exec.result(finished) == {:ok, %{left: %{}, right: %{}}}
  end

  test "native inspection is explicit and does not consume work" do
    assert {:ok, execution} = Exec.start(MathFlow, %{value: 3})
    ready = Exec.ready(execution)

    assert %{workflow: %Runic.Workflow{}, compiled: %Jido.Flow.Compiled{}, ready: [_]} =
             Exec.native(execution)

    assert Exec.ready(execution) == ready
    refute function_exported?(Exec, :workflow, 1)
    refute function_exported?(Exec, :compiled, 1)
    assert {:ok, _} = Exec.continue(execution)
  end

  defp recorder_flow do
    Flow.new!(
      name: "token_selection",
      components:
        Enum.map(["a", "b"], &Step.new!(name: &1, action: RecorderAction, params: %{value: &1})),
      output: %{a: Ref.result("a"), b: Ref.result("b")}
    )
  end

  defp map_flow do
    Flow.new!(
      name: "map_inspection",
      components: [
        FlowMap.new!(
          name: "mapped",
          collection: Ref.input(:items),
          action: EchoParamsAction,
          params: %{value: Ref.item()}
        )
      ],
      output: %{items: Ref.result("mapped")}
    )
  end

  defp collect(execution, collected \\ []) do
    case Exec.ready(execution) do
      [] ->
        {Enum.reverse(collected), execution}

      [_ | _] ->
        assert {:ok, work, next} = Exec.step(execution)
        assert next.revision == execution.revision + 1
        collect(next, [work | collected])
    end
  end
end
