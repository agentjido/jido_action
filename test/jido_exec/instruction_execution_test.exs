defmodule JidoActionTest.Exec.InstructionExecutionTest do
  use ExUnit.Case, async: true

  alias Jido.Action.Error.{ConfigurationError, InvalidInputError}
  alias Jido.Exec
  alias Jido.Instruction
  alias JidoActionTest.Fixtures.MathFlow
  alias JidoActionTest.Fixtures.Actions.Add

  defmodule CountingDescriptorAction do
    def __jido_executable__ do
      if counter = Process.get(:descriptor_counter) do
        Agent.update(counter, &(&1 + 1))
      end

      Jido.Executable.action(__MODULE__)
    end

    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
    def run(params, _context), do: {:ok, params}
  end

  test "resolves each execution target once" do
    counter = start_supervised!({Agent, fn -> 0 end})
    Process.put(:descriptor_counter, counter)

    assert Exec.run(CountingDescriptorAction, %{value: 1}) == {:ok, %{value: 1}}
    assert Agent.get(counter, & &1) == 1

    instruction = Instruction.new!(target: CountingDescriptorAction, params: %{value: 2})
    assert Agent.get(counter, & &1) == 2

    assert Exec.run(instruction) == {:ok, %{value: 2}}
    assert Agent.get(counter, & &1) == 3
  end

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

    assert {:error, %ConfigurationError{}} =
             Exec.run(instruction)

    assert {:error, %ConfigurationError{}} = Exec.start(instruction)
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
