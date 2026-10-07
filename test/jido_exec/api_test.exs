defmodule Jido.Exec.ApiTest do
  use ExUnit.Case, async: true

  alias Jido.Exec
  alias Jido.Instruction
  alias JidoActionTest.Fixtures.Actions.{Add, BasicAction, ErrorAction, ExtrasAction}

  test "compile/2 returns a real one-node Runic Workflow" do
    assert {:ok, %Runic.Workflow{} = workflow} = Exec.compile(Add)
    assert %Jido.Exec.Node.Action{} = Runic.Workflow.get_component(workflow, "add_one")
  end

  test "run/4 executes an Action module through Runic" do
    assert Exec.run(Add, %{value: 3, amount: 4}) == {:ok, %{value: 7}}
  end

  test "run/4 executes a bound Instruction through the same path" do
    instruction = Instruction.new!(target: Add, params: %{amount: 3})

    assert Exec.run(instruction, %{value: 4}) == {:ok, %{value: 7}}
  end

  test "run/4 returns deferred effects" do
    assert Exec.run(ExtrasAction, %{value: 8}, %{trace_id: "trace-1"}) ==
             {:ok, %{value: 8}, [%{trace_id: "trace-1"}]}
  end

  test "run/4 projects validation failures" do
    assert {:error, %Jido.Action.Error.InvalidInputError{}} =
             Exec.run(BasicAction, %{value: "bad"})
  end

  test "run/4 projects Action exceptions" do
    assert {:error, %Jido.Action.Error.ExecutionFailureError{details: %{phase: :run}}} =
             Exec.run(ErrorAction, %{error_type: :runtime})
  end
end
