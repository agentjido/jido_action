defmodule JidoTest.FlowExampleTest do
  use JidoTest.ActionCase, async: false

  alias Jido.Examples.FlowExample
  alias Jido.Exec.Result

  test "checkout flow runs through fan-out, retry, fan-in, and introspection" do
    assert {:ok, %Result{} = result} = FlowExample.run_checkout("cart_123")

    assert result.status == :ok

    assert result.results.reserve_inventory == [
             %{cart_id: "cart_123", reserved?: true, hold_id: "hold-cart_123", attempts: 2}
           ]

    assert result.results.build_receipt == [
             %{
               receipt_id: "receipt-cart_123",
               cart_id: "cart_123",
               total_cents: 6062,
               hold_id: "hold-cart_123",
               reserved?: true
             }
           ]

    snapshot = FlowExample.inspect_result(result)

    assert snapshot.summary.satisfied?
    assert Enum.any?(snapshot.graph.edges, &(&1.from == :load_cart and &1.to == :price_cart))

    assert Enum.any?(
             snapshot.graph.edges,
             &(&1.from == :load_cart and &1.to == :reserve_inventory)
           )
  end

  test "running total flow preserves state across repeated execution" do
    assert {:ok, %Result{} = result} = FlowExample.run_running_total([2, 3, 5])

    assert 10 in Runic.Workflow.raw_productions(result.workflow, :running_total)
  end
end
