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
              %{
                items: [
                  %{index: 0, value: 3},
                  %{index: 1, value: 1},
                  %{index: 2, value: 2}
                ]
              }}

    assert Exec.run(flow, %{items: []}) == {:ok, %{items: []}}
  end

  test "Map can collect Action errors as ordered data" do
    flow = map_flow(FallibleAction, %{value: Ref.item()}, :collect_errors)

    assert {:ok, %{items: [first, failed, third]}} = Exec.run(flow, %{items: [:a, :bad, :c]})
    assert first == %{status: :ok, value: %{value: :a}}

    assert %{
             status: :error,
             error: %{
               type: :execution_error,
               message: "bad_item",
               retryable?: false,
               details: details
             }
           } = failed

    assert %{node: "items", target: FallibleAction, item_index: 1, item_id: item_id} = details
    assert is_binary(item_id)
    refute Map.has_key?(details, :stacktrace)
    assert third == %{status: :ok, value: %{value: :c}}
  end

  test "Map collects parameter reference failures without item identity" do
    flow = map_flow(EchoParamsAction, %{value: Ref.item(:value)}, :collect_errors)

    assert {:ok, %{items: [first, failed, third]}} =
             Exec.run(flow, %{items: [%{value: 1}, %{}, %{value: 3}]})

    assert first == %{status: :ok, value: %{value: 1}}
    assert third == %{status: :ok, value: %{value: 3}}

    assert %{status: :error, error: %{type: :flow_execution_error, details: details}} = failed
    assert %{reason: :missing_key, path: [:value], ref_type: :item} = details
    refute Map.has_key?(details, :item_id)
    refute Map.has_key?(details, :item_index)
    refute Map.has_key?(details, :target)
  end

  test "Map handles a large collection read from Flow input" do
    flow = map_flow(EchoParamsAction, %{value: Ref.item()}, :fail_fast)
    items = Enum.to_list(1..1_000)

    assert {:ok, %{items: results}} = Exec.run(flow, %{items: items})
    assert Enum.map(results, & &1.value) == items
  end

  test "Map item IDs follow the Flow, component name, and source index" do
    flow =
      Flow.new!(%{
        name: "map_ids",
        components:
          for name <- ["left", "right"] do
            %{
              kind: :map,
              name: name,
              collection: Ref.input(:items),
              action: EchoParamsAction,
              params: %{id: Ref.item_id()}
            }
          end,
        output: %{left: Ref.result("left"), right: Ref.result("right")}
      })

    assert {:ok, %{left: [%{id: left}], right: [%{id: right}]}} = Exec.run(flow, %{items: [1]})
    assert left != right
    assert {:ok, %{left: [%{id: ^left}]}} = Exec.run(flow, %{items: [2]})
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
      output: %{items: Ref.result("items")}
    })
  end
end
