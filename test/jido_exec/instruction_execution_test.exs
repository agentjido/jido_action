defmodule JidoActionTest.Exec.InstructionExecutionTest do
  use ExUnit.Case, async: true

  alias Jido.Action.Error.InvalidInputError
  alias Jido.Exec
  alias Jido.Instruction
  alias JidoActionTest.Fixtures.MathFlow
  alias JidoActionTest.Fixtures.Actions.Add

  test "merges Instruction and call-site input and context" do
    instruction =
      Instruction.new!(
        target: Add,
        params: %{value: 5, amount: 1},
        context: %{trace_id: "base"}
      )

    assert {:ok, %{value: 8}} =
             Exec.run(instruction, %{amount: 3}, %{tenant_id: "tenant"})
  end

  test "rejects invalid call-site input" do
    instruction = Instruction.new!(target: Add)

    assert {:error, %InvalidInputError{message: message}} =
             Exec.run(instruction, :not_params, %{})

    assert message =~ "expected params to be a map or keyword list"
  end

  test "rejects malformed raw Instruction structs" do
    instruction = %Instruction{target: "not_a_module", params: %{}, context: %{}}

    assert {:error, %InvalidInputError{message: "Invalid instruction configuration"}} =
             Exec.run(instruction)
  end

  test "runs module and runtime Flow Instructions with Flow options" do
    for target <- [MathFlow, MathFlow.flow()] do
      instruction =
        Instruction.new!(
          target: target,
          params: %{value: 2},
          context: %{tenant: "acme"}
        )

      assert {:ok, %{value: 8}} =
               Exec.run(instruction, %{value: 3}, %{}, async: true, max_concurrency: 2)
    end
  end

  test "starts module and runtime Flow Instructions step-wise" do
    for target <- [MathFlow, MathFlow.flow()] do
      instruction = Instruction.new!(target: target, params: %{value: 3})

      assert {:ok, execution} = Exec.start(instruction)
      assert [%Runic.Workflow.Runnable{}] = Exec.ready(execution)
      assert {:ok, execution} = Exec.continue(execution)
      assert Exec.result(execution) == {:ok, %{value: 8}}
    end
  end

  test "rejects step-wise execution for an Action Instruction" do
    instruction = Instruction.new!(target: Add, params: %{value: 1})

    assert {:error, %InvalidInputError{details: %{executable_type: :instruction}}} =
             Exec.start(instruction)
  end
end
