defmodule Jido.Exec.CollectionRuntimeTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Action.Error.InvalidInputError
  alias Jido.Exec
  alias Jido.Flow
  alias Jido.Flow.{Node, Reduce, Ref}
  alias Jido.Flow.Map, as: FlowMap
  alias JidoTest.ExecFixtures.{MapNestedFlow, PreflightRecorder, ReduceNestedFlow, Transforms}
  alias JidoTest.TestActions.MissingRun

  describe "Map and Reduce target execution" do
    test "runs each nested Map Flow input and output boundary exactly once" do
      target = MapNestedFlow

      flow =
        Flow.new!(
          name: "map_nested_once",
          nodes: [
            FlowMap.new!(
              name: :mapped,
              collection: Ref.value([3, 4]),
              action: target,
              input: %{value: Ref.item()}
            )
          ],
          return: Ref.result(:mapped)
        )

      reset_flow_transform_counts()

      assert {:ok, %{results: results, errors: []}} = Exec.run(flow)
      assert Enum.map(results, & &1.output.value) == [3, 4]
      assert Enum.map(results, & &1.output.input_passes) == [1, 1]
      assert Enum.map(results, & &1.output.output_passes) == [1, 1]
      assert Transforms.calls(:input) == 2
      assert Transforms.calls(:output) == 2
    end

    test "runs each nested Reduce Flow input and output boundary exactly once" do
      target = ReduceNestedFlow

      flow =
        Flow.new!(
          name: "reduce_nested_once",
          nodes: [
            Reduce.new!(
              name: :reduced,
              collection: Ref.value([3, 4]),
              initial: Ref.value(%{value: nil}),
              action: target,
              input: %{
                value: Ref.item(),
                previous: Ref.accumulator(:value)
              }
            )
          ],
          return: Ref.result(:reduced)
        )

      reset_flow_transform_counts()

      assert {:ok,
              %{
                value: 4,
                previous: 3,
                input_passes: 1,
                output_passes: 1
              }} = Exec.run(flow)

      assert Transforms.calls(:input) == 2
      assert Transforms.calls(:output) == 2
    end

    test "preflights an empty Map target before any public node runs" do
      before = PreflightRecorder

      flow =
        Flow.new!(
          name: "empty_map_preflight",
          nodes: [
            Node.new!(
              name: :before,
              action: before,
              input: %{test_pid: Ref.context(:test_pid)}
            ),
            FlowMap.new!(
              name: :mapped,
              collection: Ref.value([]),
              action: MissingRun,
              input: Ref.item()
            )
          ],
          return: Ref.result(:mapped)
        )

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Exec.run(flow, %{}, %{test_pid: self()})

      assert message == "module is not a valid Jido action"
      assert details.map == "mapped"
      assert details.target == MissingRun
      refute_received {^before, :run}
    end

    test "preflights an empty Reduce target before any public node runs" do
      before = PreflightRecorder

      flow =
        Flow.new!(
          name: "empty_reduce_preflight",
          nodes: [
            Node.new!(
              name: :before,
              action: before,
              input: %{test_pid: Ref.context(:test_pid)}
            ),
            Reduce.new!(
              name: :reduced,
              collection: Ref.value([]),
              initial: Ref.value(%{}),
              action: MissingRun,
              input: Ref.accumulator()
            )
          ],
          return: Ref.result(:reduced)
        )

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Exec.run(flow, %{}, %{test_pid: self()})

      assert message == "module is not a valid Jido action"
      assert details.reduce == "reduced"
      assert details.target == MissingRun
      refute_received {^before, :run}
    end
  end

  defp reset_flow_transform_counts do
    Transforms.reset()
  end
end
