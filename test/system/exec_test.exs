defmodule JidoActionTest.System.ExecTest do
  use ExUnit.Case, async: true

  @moduletag :system

  alias Jido.Exec
  alias Jido.Flow.Ref
  alias JidoActionTest.Fixtures.Actions.{Add, Multiply}

  test "one compiled Runic workflow executes through each public target form" do
    flow =
      JidoActionTest.FlowBuilder.new!(
        name: "exec_v2_system",
        components: [
          JidoActionTest.FlowComponent.step!(
            name: "add",
            action: Add,
            params: %{value: Ref.input(:value), amount: 1}
          ),
          JidoActionTest.FlowComponent.step!(
            name: "multiply",
            action: Multiply,
            params: %{value: Ref.result("add", :value), amount: 2}
          )
        ],
        output: Ref.result("multiply")
      )

    instruction = Jido.Instruction.new!(target: flow, kind: :flow, params: %{value: 3})

    assert {:ok, %Runic.Workflow{} = workflow} = Exec.compile(flow)
    assert %Jido.Exec.Node.Action{} = Runic.Workflow.get_component(workflow, "add")
    assert %Jido.Exec.Node.Action{} = Runic.Workflow.get_component(workflow, "multiply")
    assert Exec.run(flow, %{value: 3}) == {:ok, %{value: 8}}
    assert Exec.run(instruction) == {:ok, %{value: 8}}
  end
end
