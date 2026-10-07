defmodule Jido.Exec.CompilerTest do
  use ExUnit.Case, async: true

  alias Jido.Exec
  alias Jido.Flow
  alias Jido.Flow.Ref
  alias JidoActionTest.Fixtures.Actions.{Add, Multiply}

  test "a serial Flow compiles to connected Action nodes" do
    flow =
      flow!(
        "serial",
        [
          step("add", Add, %{value: Ref.input(:value), amount: 1}),
          step("multiply", Multiply, %{value: Ref.result("add", :value), amount: 2})
        ],
        Ref.result("multiply")
      )

    assert {:ok, %Runic.Workflow{} = workflow} = Exec.compile(flow)
    assert %Jido.Exec.Node.Action{} = Runic.Workflow.get_component(workflow, "add")
    assert %Jido.Exec.Node.Action{} = Runic.Workflow.get_component(workflow, "multiply")

    assert Exec.run(flow, %{value: 3}) == {:ok, %{value: 8}}
  end

  test "a nested Flow uses a native Runic Workflow boundary" do
    flow =
      flow!(
        "nested",
        [
          %{
            kind: :subflow,
            name: "inner",
            flow: JidoActionTest.Fixtures.NestedFlow,
            params: %{value: Ref.input(:value)}
          },
          step("after", Multiply, %{value: Ref.result("inner", :value), amount: 2})
        ],
        Ref.result("after")
      )

    workflow = Exec.compile!(flow)
    assert %Runic.Workflow{} = Runic.Workflow.get_component(workflow, "inner")

    rebuilt = workflow |> Runic.Workflow.build_log() |> Runic.Workflow.from_log()
    assert %Runic.Workflow{} = Runic.Workflow.get_component(rebuilt, "inner")
    assert Exec.run(flow, %{value: 3}) == {:ok, %{value: 8}}
  end

  defp flow!(name, components, output) do
    Flow.new!(%{name: name, components: components, output: output})
  end

  defp step(name, action, params) do
    %{kind: :step, name: name, action: action, params: params}
  end
end
