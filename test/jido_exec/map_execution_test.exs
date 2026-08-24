defmodule Jido.Exec.MapExecutionTest do
  use JidoTest.ActionCase, async: true

  @moduletag capture_log: true

  alias Jido.Action.Error.ExecutionFailureError
  alias Jido.Exec
  alias Jido.Exec.NodeResult
  alias Jido.Flow
  alias Jido.Flow.Map, as: FlowMap
  alias Jido.Flow.{Node, Ref}
  alias JidoTest.ExecutionFixtures
  alias JidoTest.TestActions.{MapProbeAction, RecorderAction}

  describe "Map step-wise execution" do
    test "exposes one public Map node and completes all serial item work in one step" do
      flow =
        ExecutionFixtures.map_flow(
          [%{value: :zero, outcome: :ok}, %{value: :one, outcome: :ok}],
          :fail_fast
        )

      assert {:ok, execution} = Exec.start(flow, %{}, %{test_pid: self()})
      assert Exec.ready(execution) == ["mapped"]

      assert {:ok,
              %NodeResult{
                node: "mapped",
                status: :ok,
                output: %{results: results, errors: []},
                attempt: 1
              }, execution} = Exec.step(execution)

      assert Enum.map(results, & &1.index) == [0, 1]
      assert Exec.status(execution) == :succeeded
      refute inspect(execution) =~ "item_"
    end

    @tag timeout: 5_000
    test "shares one concurrency cap across independent Map nodes" do
      items = [
        %{value: :zero, outcome: :ok, block: true},
        %{value: :one, outcome: :ok, block: true}
      ]

      flow =
        Flow.new!(
          name: "shared_map_concurrency",
          nodes: [
            FlowMap.new!(
              name: :left,
              collection: Ref.value(items),
              action: MapProbeAction,
              input: ExecutionFixtures.map_probe_input(),
              on_error: :collect_errors
            ),
            FlowMap.new!(
              name: :right,
              collection: Ref.value(items),
              action: MapProbeAction,
              input: ExecutionFixtures.map_probe_input(),
              on_error: :collect_errors
            )
          ],
          return: %{left: Ref.result(:left), right: Ref.result(:right)}
        )

      owner = self()

      task =
        Task.async(fn ->
          Exec.run(flow, %{}, %{test_pid: owner}, async: true, max_concurrency: 2)
        end)

      first_workers = receive_started_workers(2)
      refute_receive {MapProbeAction, :started, _index, _worker}, 50
      Enum.each(first_workers, &send(&1, :release))

      [third_worker] = receive_started_workers(1)
      send(third_worker, :release)
      [fourth_worker] = receive_started_workers(1)
      send(fourth_worker, :release)

      assert {:ok, %{left: %{results: [_, _]}, right: %{results: [_, _]}}} = Task.await(task)
    end

    @tag timeout: 5_000
    test "uses the stored node-local concurrency cap inside step/2" do
      items =
        Enum.map(0..3, fn index ->
          %{value: index, outcome: :ok, block: true}
        end)

      flow = ExecutionFixtures.map_flow(items, :collect_errors)

      assert {:ok, execution} =
               Exec.start(flow, %{}, %{test_pid: self()}, async: true, max_concurrency: 2)

      task = Task.async(fn -> Exec.step(execution, "mapped") end)

      assert_receive {MapProbeAction, :started, first_index, first_worker}
      assert_receive {MapProbeAction, :started, second_index, second_worker}
      assert Enum.sort([first_index, second_index]) == [0, 1]
      refute_receive {MapProbeAction, :started, 2, _worker}, 50

      send(first_worker, :release)
      send(second_worker, :release)

      assert_receive {MapProbeAction, :started, third_index, third_worker}
      assert_receive {MapProbeAction, :started, fourth_index, fourth_worker}
      assert Enum.sort([third_index, fourth_index]) == [2, 3]
      send(third_worker, :release)
      send(fourth_worker, :release)

      assert {:ok, %NodeResult{output: %{results: results, errors: []}}, execution} =
               Task.await(task)

      assert Enum.map(results, & &1.index) == [0, 1, 2, 3]

      assert Exec.result(execution) ==
               {:ok, %{kind: :jido_flow_map_result, results: results, errors: []}}
    end

    test "uses bounded fail-fast windows and selects the lowest failed source index" do
      items = [
        %{value: :zero, outcome: {:error, "zero failed"}},
        %{value: :one, outcome: :ok},
        %{value: :two, outcome: {:error, "two failed"}},
        %{value: :three, outcome: :ok}
      ]

      assert {:ok, execution} =
               Exec.start(ExecutionFixtures.map_flow(items, :fail_fast), %{}, %{test_pid: self()},
                 async: true,
                 max_concurrency: 3
               )

      assert {:ok,
              %NodeResult{
                status: :error,
                output: nil,
                error: %ExecutionFailureError{message: "zero failed", details: details},
                attempt: 1
              }, execution} = Exec.step(execution)

      assert details.item_index == 0
      assert_receive {MapProbeAction, :started, 0, _worker}
      assert_receive {MapProbeAction, :started, 1, _worker}
      assert_receive {MapProbeAction, :started, 2, _worker}
      refute_received {MapProbeAction, :started, 3, _worker}
      assert Exec.status(execution) == :failed
    end

    test "contains an async item Action exit in an ordered collected error" do
      items = [%{value: :zero, outcome: :kill}, %{value: :one, outcome: :ok}]

      assert {:ok, execution} =
               Exec.start(
                 ExecutionFixtures.map_flow(items, :collect_errors),
                 %{},
                 %{test_pid: self()},
                 async: true,
                 max_concurrency: 2
               )

      assert {:ok,
              %NodeResult{
                status: :ok,
                output: %{results: [%{index: 1}], errors: [%{index: 0, error: error}]}
              }, execution} = Exec.step(execution)

      assert %ExecutionFailureError{
               message: "action execution process exited",
               details: details
             } = error

      assert details.phase == :map_target_execution
      assert details.node == "mapped"
      assert details.action == MapProbeAction
      assert details.target == MapProbeAction
      assert details.item_index == 0
      assert details.reason == :killed
      assert Exec.status(execution) == :succeeded
    end

    test "stops after a failed Map before it dispatches independent work" do
      map =
        FlowMap.new!(
          name: :mapped,
          collection: Ref.value([%{value: :bad, outcome: {:error, "failed"}}]),
          action: MapProbeAction,
          input: ExecutionFixtures.map_probe_input(),
          on_error: :fail_fast
        )

      flow =
        Flow.new!(
          name: "map_failure_dependencies",
          nodes: [
            map,
            Node.new!(
              name: :dependent,
              action: RecorderAction,
              input: %{value: Ref.result(:mapped)}
            ),
            Node.new!(
              name: :independent,
              action: RecorderAction,
              input: %{value: Ref.value(:independent)}
            )
          ],
          return: Ref.result(:independent)
        )

      assert {:ok, execution} = Exec.start(flow, %{}, %{test_pid: self()})
      assert Exec.ready(execution) == ["independent", "mapped"]
      assert {:ok, %NodeResult{status: :error}, execution} = Exec.step(execution, "mapped")
      assert Exec.ready(execution) == []
      assert Exec.status(execution) == :failed
      refute_received {RecorderAction, %{value: :independent}}
      refute_received {RecorderAction, %{value: %{kind: :jido_flow_map_result}}}
    end
  end

  describe "Map to Reduce step-wise execution" do
    test "keeps Reduce as one public serial Step in ready, wave, and continue paths" do
      flow = ExecutionFixtures.map_reduce_flow(:success)

      assert {:ok, execution} =
               Exec.start(flow, %{}, %{test_pid: self()}, async: true, max_concurrency: 2)

      assert Exec.ready(execution) == ["mapped"]

      assert {:ok, [%NodeResult{node: "mapped", status: :ok}], execution} =
               Exec.wave(execution)

      assert Exec.ready(execution) == ["reduced"]

      assert {:ok,
              %NodeResult{
                node: "reduced",
                status: :ok,
                output: %{values: [:zero, :one], indexes: [0, 1]},
                attempt: 1
              }, execution} = Exec.step(execution, "reduced")

      assert Exec.ready(execution) == []
      assert Exec.status(execution) == :succeeded
      assert Exec.result(execution) == {:ok, %{values: [:zero, :one], indexes: [0, 1]}}
      refute inspect(execution) =~ "reduce_item"

      assert {:ok, continued} = Exec.start(flow, %{}, %{test_pid: self()})
      assert {:ok, continued} = Exec.continue(continued)
      assert Exec.result(continued) == {:ok, %{values: [:zero, :one], indexes: [0, 1]}}
    end

    test "returns one error NodeResult when direct collected Map errors reach Reduce" do
      assert {:ok, execution} =
               Exec.start(ExecutionFixtures.map_reduce_flow(:with_error), %{}, %{test_pid: self()})

      assert {:ok, %NodeResult{node: "mapped", status: :ok}, execution} = Exec.step(execution)
      assert Exec.ready(execution) == ["reduced"]

      assert {:ok,
              %NodeResult{
                node: "reduced",
                status: :error,
                output: nil,
                error: %ExecutionFailureError{
                  message: "reduce cannot consume a Map result with errors",
                  details: %{reason: :map_errors_present, error_indices: [1]}
                },
                attempt: 1
              }, execution} = Exec.step(execution)

      assert Exec.status(execution) == :failed
    end
  end

  defp receive_started_workers(count) do
    Enum.map(1..count, fn _index ->
      assert_receive {MapProbeAction, :started, _item_index, worker}, 1_000
      worker
    end)
  end
end
