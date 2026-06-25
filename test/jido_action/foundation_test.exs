defmodule JidoTest.FoundationTest do
  use ExUnit.Case, async: true

  test "base package exposes action, instruction, and v4 flow/exec foundations" do
    assert Code.ensure_loaded?(Jido.Action)
    assert Code.ensure_loaded?(Jido.Instruction)
    assert Code.ensure_loaded?(Jido.Flow)
    assert Code.ensure_loaded?(Jido.Flow.Node)
    assert Code.ensure_loaded?(Jido.Flow.Ref)
    assert Code.ensure_loaded?(Jido.Exec)

    refute Code.ensure_loaded?(Jido.Flow.Step)
    refute Code.ensure_loaded?(Jido.Flow.Switch)
    refute Code.ensure_loaded?(Jido.Exec.Result)
    refute Code.ensure_loaded?(Jido.Exec.Telemetry)
  end
end
