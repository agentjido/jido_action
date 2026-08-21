defmodule Jido.Flow.GraphValidationTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Action.Error.InvalidInputError
  alias Jido.Flow
  alias Jido.Flow.{Node, Ref}
  alias JidoTest.TestActions.Add

  test "validates long dependency chains with near-linear Jido-owned work" do
    small_nodes = chain_nodes(200)
    large_nodes = chain_nodes(400)

    small_reductions = validation_reductions(small_nodes)
    large_reductions = validation_reductions(large_nodes)

    assert large_reductions < small_reductions * 3
  end

  test "canonical ordering keeps dependency waves and name ordering stable" do
    flow =
      Flow.new!(
        name: "canonical_waves",
        nodes: [
          flow_node("y", ["a"]),
          flow_node("b", ["z"]),
          flow_node("z"),
          flow_node("a")
        ],
        return: Ref.result("y")
      )

    assert Enum.map(Flow.canonical_nodes(flow.nodes), & &1.name) == ["a", "z", "b", "y"]
  end

  test "cycle errors retain the sorted blocked-node details" do
    assert {:error,
            %InvalidInputError{
              message: "flow dependency graph contains a cycle",
              details: %{nodes: ["cycle_a", "cycle_b", "downstream"]}
            }} =
             Flow.new(
               name: "partially_blocked",
               nodes: [
                 flow_node("downstream", ["cycle_a"]),
                 flow_node("root"),
                 flow_node("cycle_b", ["cycle_a"]),
                 flow_node("cycle_a", ["cycle_b"])
               ],
               return: Ref.result("downstream")
             )
  end

  defp validation_reductions(nodes) do
    before_reductions = process_reductions()

    assert {:ok, _flow} =
             Flow.new(
               name: "long_chain",
               nodes: nodes,
               return: Ref.result(List.last(nodes).name)
             )

    process_reductions() - before_reductions
  end

  defp process_reductions do
    self()
    |> Process.info(:reductions)
    |> elem(1)
  end

  defp chain_nodes(count) do
    Enum.map(0..(count - 1), fn
      0 -> flow_node("node_0")
      index -> flow_node("node_#{index}", ["node_#{index - 1}"])
    end)
  end

  defp flow_node(name, deps \\ []) do
    Node.new!(
      name: name,
      action: Add,
      input: %{value: Ref.input(:value)},
      deps: deps
    )
  end
end
