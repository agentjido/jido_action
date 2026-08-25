defmodule JidoActionTest.Exec.IteratorNestedExecutionTest do
  use ExUnit.Case, async: true

  @moduletag capture_log: true

  alias Jido.Exec
  alias Jido.Exec.NodeResult
  alias Jido.Action.Error.InvalidInputError
  alias Jido.Flow
  alias Jido.Flow.Iterator
  alias Jido.Flow.Map, as: FlowMap
  alias Jido.Flow.Ref
  alias JidoActionTest.IteratorFixtures
  alias JidoActionTest.IteratorFixtures.{ChildIterator, ChildMapReduce, Increment}

  describe "nested Iterator execution" do
    test "runs a marked child Flow atomically with fresh child Iterator State" do
      flow =
        IteratorFixtures.iterator_flow(
          action: ChildIterator,
          initial: %{count: Ref.value(0)},
          update: %{count: Ref.state(:count)},
          completion: IteratorFixtures.gte(Ref.iteration_index(), Ref.value(2)),
          max_iterations: 2
        )

      assert {:ok,
              %{
                iterations: 2,
                state: %{count: 0},
                output: %{iterations: 1, state: %{count: 1}}
              }} = Exec.run(flow, %{}, %{test_pid: self()}, async: true, max_concurrency: 4)

      assert_receive {Increment, 0}
      assert_receive {Increment, 0}
      refute_received {Increment, 1}
    end

    test "allows nested Map and Reduce to return one serial State candidate" do
      iterator =
        Iterator.new!(
          name: :aggregate,
          action: ChildMapReduce,
          input: %{items: Ref.state(:items)},
          state: [
            schema: [],
            initial: %{items: Ref.input(:items), total: Ref.value(0)},
            update: %{items: Ref.state(:items), total: Ref.body_result(:value)}
          ],
          completion: IteratorFixtures.gte(Ref.iteration_index(), Ref.value(1)),
          max_iterations: 1
        )

      flow =
        Flow.new!(name: "iterator_map_reduce", nodes: [iterator], return: Ref.result(:aggregate))

      assert {:ok,
              %{
                iterations: 1,
                state: %{items: [%{value: 1}, %{value: 2}], total: 6},
                output: %{value: 6}
              }} = Exec.run(flow, %{items: [%{value: 1}, %{value: 2}]}, %{})
    end

    test "creates fresh child Iterator State for every Map item" do
      map =
        FlowMap.new!(
          name: :per_item,
          collection: Ref.input(:items),
          action: ChildIterator,
          input: %{item: Ref.item()}
        )

      flow = Flow.new!(name: "map_child_iterators", nodes: [map], return: Ref.result(:per_item))

      assert {:ok, %{results: results, errors: []}} =
               Exec.run(
                 flow,
                 %{items: [%{seed: 10}, %{seed: 20}]},
                 %{test_pid: self()},
                 async: true,
                 max_concurrency: 2
               )

      assert Enum.map(results, & &1.output.state) == [%{count: 1}, %{count: 1}]
      assert Enum.map(results, & &1.output.iterations) == [1, 1]
      assert_receive {Increment, 0}
      assert_receive {Increment, 0}
      refute_received {Increment, 1}
    end

    test "is one public step and rejects concurrent stale Execution reuse" do
      flow =
        IteratorFixtures.iterator_flow(
          initial: %{count: Ref.value(0)},
          completion: IteratorFixtures.gte(Ref.state(:count), Ref.value(1)),
          max_iterations: 1
        )

      assert {:ok, execution} = Exec.start(flow, %{}, %{test_pid: self()})
      assert Exec.ready(execution) == ["count"]

      first_task = Task.async(fn -> Exec.step(execution) end)
      second_task = Task.async(fn -> Exec.step(execution) end)

      results = [Task.await(first_task), Task.await(second_task)]

      assert [{:ok, %NodeResult{node: "count", status: :ok}, completed}] =
               Enum.filter(results, &match?({:ok, %NodeResult{}, _execution}, &1))

      assert [{:error, %InvalidInputError{message: "stale flow execution"} = error}] =
               Enum.filter(results, &match?({:error, %InvalidInputError{}}, &1))

      assert completed.revision == 1
      assert error.details.reason == :operation_in_progress
      assert {:ok, %{iterations: 1, state: %{count: 1}}} = Exec.result(completed)
      assert_receive {Increment, 0}
      refute_receive {Increment, 0}
    end

    test "runs independent Iterator nodes with isolated State cells in one async wave" do
      left =
        Iterator.new!(
          name: :left,
          action: Increment,
          input: %{count: Ref.state(:count), index: Ref.iteration_index()},
          state: [
            schema: [],
            initial: %{count: Ref.value(0)},
            update: %{count: Ref.body_result(:count)}
          ],
          completion: IteratorFixtures.gte(Ref.iteration_index(), Ref.value(1)),
          max_iterations: 1
        )

      right =
        Iterator.new!(
          name: :right,
          action: Increment,
          input: %{count: Ref.state(:count), index: Ref.iteration_index()},
          state: [
            schema: [],
            initial: %{count: Ref.value(10)},
            update: %{count: Ref.body_result(:count)}
          ],
          completion: IteratorFixtures.gte(Ref.iteration_index(), Ref.value(1)),
          max_iterations: 1
        )

      flow =
        Flow.new!(
          name: "parallel_iterators",
          nodes: [right, left],
          return: %{left: Ref.result(:left), right: Ref.result(:right)}
        )

      assert {:ok, execution} = Exec.start(flow, %{}, %{}, async: true, max_concurrency: 2)
      assert Exec.ready(execution) == ["left", "right"]

      assert {:ok, [left_result, right_result], execution} = Exec.wave(execution)
      assert left_result.output.state == %{count: 1}
      assert right_result.output.state == %{count: 11}
      assert Exec.status(execution) == :succeeded
    end
  end
end
