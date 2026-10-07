defmodule JidoActionTest.Exec.FlowOwnershipTest do
  use ExUnit.Case, async: true

  test "native Flow compilation and runtime helpers belong to Exec" do
    assert Code.ensure_loaded?(Jido.Exec.Flow.Compiler)
    assert Code.ensure_loaded?(Jido.Exec.Flow.Compiled)
    assert Code.ensure_loaded?(Jido.Exec.Flow.Collection)
    assert Code.ensure_loaded?(Jido.Exec.Flow.ValueResolver)
    assert Code.ensure_loaded?(Jido.Exec.Flow.Frame)
    assert Code.ensure_loaded?(Jido.Exec.Flow.Iterator)
    assert Code.ensure_loaded?(Jido.Exec.Flow.Payload)
    assert Code.ensure_loaded?(Jido.Exec.Flow.Target)
    assert Code.ensure_loaded?(Jido.Exec.Flow.Validator)

    refute Code.ensure_loaded?(Jido.Flow.Compiled)
    refute Code.ensure_loaded?(Jido.Flow.Compiler)
    refute Code.ensure_loaded?(Jido.Flow.Compiler.Collection)
    refute Code.ensure_loaded?(Jido.Flow.Compiler.Iterator)
    refute Code.ensure_loaded?(Jido.Flow.Compiler.Target)
  end
end
