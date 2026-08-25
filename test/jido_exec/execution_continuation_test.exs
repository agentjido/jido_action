defmodule JidoActionTest.Exec.ExecutionContinuationTest do
  use ExUnit.Case, async: true

  alias Jido.Exec
  alias Jido.Exec.NodeResult
  alias Jido.Flow
  alias Jido.Flow.{Node, Ref}
  alias JidoActionTest.ExecFixtures
  alias JidoActionTest.TestActions.EchoParamsAction

  describe "continue/1 and run/4 alignment" do
    test "continues to completion with the same result as run/4" do
      flow = ExecFixtures.diamond_flow(EchoParamsAction)

      assert {:ok, execution} = Exec.start(flow)
      assert {:ok, execution} = Exec.continue(execution)
      assert Exec.status(execution) == :succeeded
      assert Exec.result(execution) == Exec.run(flow)
    end

    test "validates input and output once and caches the final result" do
      ExecFixtures.reset_transform_counts()

      assert {:ok, execution} = Exec.start(ExecFixtures.CountedStepFlow, %{value: 3})
      assert ExecFixtures.transform_count(:input) == 1
      assert ExecFixtures.transform_count(:output) == 0

      assert {:ok, execution} = Exec.continue(execution)
      assert ExecFixtures.transform_count(:output) == 1

      assert Exec.result(execution) == {:ok, %{value: 3}}
      assert Exec.result(execution) == {:ok, %{value: 3}}
      assert ExecFixtures.transform_count(:output) == 1
    end

    test "treats a nested Flow as one outer node" do
      outer =
        Flow.new!(
          name: "outer_step_flow",
          nodes: [
            Node.new!(
              name: :nested,
              action: ExecFixtures.NestedStepFlow,
              input: %{value: Ref.input(:value)}
            )
          ],
          return: Ref.result(:nested)
        )

      assert {:ok, execution} = Exec.start(outer, %{value: 3})
      assert Exec.ready(execution) == ["nested"]

      assert {:ok, %NodeResult{node: "nested", output: %{value: 4}}, execution} =
               Exec.step(execution)

      assert Exec.status(execution) == :succeeded
      assert Exec.result(execution) == {:ok, %{value: 4}}
    end
  end
end
