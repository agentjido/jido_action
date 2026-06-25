defmodule JidoTest.FoundationTest do
  use ExUnit.Case, async: true

  test "base package exposes action and instruction without legacy flow or exec modules" do
    assert Code.ensure_loaded?(Jido.Action)
    assert Code.ensure_loaded?(Jido.Instruction)

    refute Code.ensure_loaded?(Jido.Flow)
    refute Code.ensure_loaded?(Jido.Flow.Step)
    refute Code.ensure_loaded?(Jido.Flow.Switch)
    refute Code.ensure_loaded?(Jido.Exec)
    refute Code.ensure_loaded?(Jido.Exec.Result)
    refute Code.ensure_loaded?(Jido.Exec.Telemetry)
  end
end
