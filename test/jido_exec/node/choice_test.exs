defmodule Jido.Exec.Node.ChoiceTest do
  use ExUnit.Case, async: true

  alias Jido.Exec
  alias Jido.Flow
  alias Jido.Flow.Ref
  alias JidoActionTest.Fixtures.Actions.Add

  test "Choice uses Runic Conditions and selects the first matching branch" do
    flow =
      Flow.new!(%{
        name: "choice",
        components: [
          %{
            kind: :choice,
            name: "route",
            options: [
              %{
                name: "large",
                condition: Jido.Expr.new!(:>, [Ref.input(:value), 10]),
                action: Add,
                params: %{value: Ref.input(:value), amount: 100}
              },
              %{
                name: "positive",
                condition: Jido.Expr.new!(:>, [Ref.input(:value), 0]),
                action: Add,
                params: %{value: Ref.input(:value), amount: 10}
              }
            ],
            fallback: %{action: Add, params: %{value: Ref.input(:value), amount: -10}}
          }
        ],
        output: Ref.result("route")
      })

    rebuilt = flow |> Exec.compile!() |> Runic.Workflow.build_log() |> Runic.Workflow.from_log()
    assert %Jido.Exec.Node.Choice{} = Runic.Workflow.get_component(rebuilt, "route")

    assert Enum.any?(rebuilt.graph.vertices, fn {_id, node} ->
             match?(%Runic.Workflow.Condition{}, node)
           end)

    assert Exec.run(flow, %{value: 20}) == {:ok, %{value: 120}}
    assert Exec.run(flow, %{value: 2}) == {:ok, %{value: 12}}
    assert Exec.run(flow, %{value: 0}) == {:ok, %{value: -10}}
  end
end
