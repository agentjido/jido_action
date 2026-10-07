defmodule Jido.Exec.Node.MapTest do
  use ExUnit.Case, async: true

  alias Jido.Exec
  alias Jido.Flow
  alias Jido.Flow.Ref
  alias JidoActionTest.Fixtures.Actions.EchoParamsAction

  defmodule FallibleAction do
    use Jido.Action, name: "exec_v2_fallible_map"

    @impl true
    def run(%{value: :bad}, _context), do: {:error, :bad_item}
    def run(%{value: value}, _context), do: {:ok, %{value: value}}
  end

  test "Map uses Runic FanOut and FanIn and keeps input order" do
    flow = map_flow(EchoParamsAction, %{index: Ref.item_index(), value: Ref.item()}, :fail_fast)

    rebuilt = flow |> Exec.compile!() |> Runic.Workflow.build_log() |> Runic.Workflow.from_log()
    assert %Jido.Exec.Node.Map{} = Runic.Workflow.get_component(rebuilt, "items")

    assert Enum.any?(rebuilt.graph.vertices, fn {_id, node} ->
             match?(%Runic.Workflow.FanOut{}, node)
           end)

    assert Enum.any?(rebuilt.graph.vertices, fn {_id, node} ->
             match?(%Runic.Workflow.FanIn{}, node)
           end)

    assert Exec.run(flow, %{items: [3, 1, 2]}) ==
             {:ok,
              [
                %{index: 0, value: 3},
                %{index: 1, value: 1},
                %{index: 2, value: 2}
              ]}

    assert Exec.run(flow, %{items: []}) == {:ok, []}
  end

  test "Map can collect Action errors as ordered data" do
    flow = map_flow(FallibleAction, %{value: Ref.item()}, :collect_errors)

    assert {:ok, [first, failed, third]} = Exec.run(flow, %{items: [:a, :bad, :c]})
    assert first == %{status: :ok, value: %{value: :a}}

    assert %{
             status: :error,
             error: %{
               type: "Elixir.Jido.Action.Error.ExecutionFailureError",
               message: "bad_item"
             }
           } = failed

    assert third == %{status: :ok, value: %{value: :c}}
  end

  defp map_flow(action, params, on_error) do
    Flow.new!(%{
      name: "map",
      components: [
        %{
          kind: :map,
          name: "items",
          collection: Ref.input(:items),
          action: action,
          params: params,
          on_error: on_error
        }
      ],
      output: Ref.result("items")
    })
  end
end
