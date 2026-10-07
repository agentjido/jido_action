defmodule JidoActionTest.Flow.Compiler.TargetTest do
  use ExUnit.Case, async: true

  alias Jido.Flow.Compiler.Target
  alias Jido.Flow.Step
  alias Jido.Instruction
  alias JidoActionTest.Fixtures.Actions.Add

  test "uses an Instruction as the executable Flow target" do
    target =
      Step.new!(name: "add", action: Add)
      |> Target.step()
      |> Target.at(["child"])

    params = %{value: 2, amount: 1}
    context = %{tenant: "acme"}

    runner = fn instruction, execution_id ->
      assert execution_id == "execution-1"

      assert %Instruction{
               kind: :action,
               target: Add,
               params: ^params,
               context: ^context,
               metadata: %{
                 jido_flow: %{
                   kind: :step,
                   details: %{node: "add", node_path: ["child", "add"]}
                 }
               }
             } = instruction

      {:ok, %{value: 3}, [:effect]}
    end

    assert Target.kind(target) == :step
    assert Target.details(target) == %{action: Add, node: "add", node_path: ["child", "add"]}

    assert Target.run(target, params, context, "execution-1", runner) ==
             {:ok, %{value: 3}, [:effect]}
  end
end
