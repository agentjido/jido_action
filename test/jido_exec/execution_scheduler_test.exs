defmodule JidoActionTest.Exec.ExecutionSchedulerTest do
  use ExUnit.Case, async: true

  alias Jido.Exec
  alias Jido.Exec.NodeResult
  alias JidoActionTest.ExecFixtures
  alias JidoActionTest.TestActions.EchoParamsAction

  describe "scheduler caches" do
    test "builds static indexes once and keeps the ready map and list in sync" do
      assert {:ok, execution} = Exec.start(ExecFixtures.diamond_flow(EchoParamsAction))

      node_names = Map.fetch!(execution, :node_names)
      node_positions = Map.fetch!(execution, :node_positions)

      assert node_names == MapSet.new(["left", "merge", "right"])
      assert node_positions == %{"left" => 0, "right" => 1, "merge" => 2}
      ExecFixtures.assert_ready_cache(execution, ["left", "right"])

      assert {:ok, %NodeResult{node: "left"}, execution} = Exec.step(execution)
      assert Map.fetch!(execution, :node_names) === node_names
      assert Map.fetch!(execution, :node_positions) === node_positions
      ExecFixtures.assert_ready_cache(execution, ["right"])

      assert {:ok, [%NodeResult{node: "right"}], execution} = Exec.wave(execution)
      assert Map.fetch!(execution, :node_names) === node_names
      assert Map.fetch!(execution, :node_positions) === node_positions
      ExecFixtures.assert_ready_cache(execution, ["merge"])

      assert {:ok, %NodeResult{node: "merge"}, execution} = Exec.step(execution)
      assert Exec.status(execution) == :succeeded
      assert Map.fetch!(execution, :node_names) === node_names
      assert Map.fetch!(execution, :node_positions) === node_positions
      ExecFixtures.assert_ready_cache(execution, [])
    end

    @tag timeout: 120_000
    test "steps through a 1,000-node serial flow one node at a time" do
      assert {:ok, execution} = Exec.start(ExecFixtures.serial_flow(1_000))

      execution =
        for index <- 1..1_000, reduce: execution do
          current ->
            name = ExecFixtures.node_name(index)
            assert Exec.ready(current) == [name]
            assert {:ok, %NodeResult{node: ^name}, next} = Exec.step(current)
            next
        end

      assert Exec.status(execution) == :succeeded
      ExecFixtures.assert_ready_cache(execution, [])
      assert Exec.result(execution) == {:ok, %{value: 1_000}}
    end

    @tag timeout: 120_000
    test "continues a 1,000-node serial flow to completion" do
      assert {:ok, execution} = Exec.start(ExecFixtures.serial_flow(1_000))
      assert {:ok, execution} = Exec.continue(execution)

      assert execution.revision == 1_000
      assert Exec.status(execution) == :succeeded
      ExecFixtures.assert_ready_cache(execution, [])
      assert Exec.result(execution) == {:ok, %{value: 1_000}}
    end

    @tag timeout: 120_000
    test "ready cost is isolated from total node count" do
      assert {:ok, small} = Exec.start(ExecFixtures.serial_flow(2))
      assert {:ok, large} = Exec.start(ExecFixtures.serial_flow(1_000))
      assert Exec.ready(small) == ["node_0001"]
      assert Exec.ready(large) == ["node_0001"]

      ready_reductions(small, 100)
      ready_reductions(large, 100)

      small_reductions = ready_reductions(small, 10_000)
      large_reductions = ready_reductions(large, 10_000)

      assert large_reductions <= trunc(small_reductions * 1.1) + 2_000
    end
  end

  defp ready_reductions(execution, iterations) do
    {:reductions, before_reductions} = Process.info(self(), :reductions)

    assert Enum.reduce(1..iterations, 0, fn _, count ->
             count + length(Exec.ready(execution))
           end) == iterations

    {:reductions, after_reductions} = Process.info(self(), :reductions)
    after_reductions - before_reductions
  end
end
