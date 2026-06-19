defmodule JidoTest.FlowScriptRefRendererTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Flow.Script.RefRenderer

  test "renders value references for normalized script projection" do
    assert RefRenderer.ref({:input, :order}) == "input(:order)"
    assert RefRenderer.ref({:result, :load_order}) == "result(:load_order)"
    assert RefRenderer.ref({:result, :load_order, [:items]}) == "result(:load_order, [:items])"
    assert RefRenderer.ref({:value, [1, 2]}) == "value([1, 2])"
    assert RefRenderer.ref(:items) == ":items"
  end

  test "renders over references for normalized script projection" do
    assert RefRenderer.over({:items, from: :load_order, path: [:items]}) ==
             "{:items, from: :load_order, path: [:items]}"
  end
end
