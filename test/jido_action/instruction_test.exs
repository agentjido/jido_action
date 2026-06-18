defmodule Jido.InstructionTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Instruction
  alias JidoTest.TestActions.BasicAction

  describe "validate_action_module/1" do
    test "accepts non-nil atoms" do
      assert :ok = Instruction.validate_action_module(BasicAction)
    end

    test "rejects nil and non-atoms" do
      assert {:error, "cannot be nil"} = Instruction.validate_action_module(nil)
      assert {:error, "must be an atom"} = Instruction.validate_action_module("not_a_module")
    end
  end

  describe "new/1" do
    test "creates an instruction with defaults" do
      assert {:ok, instruction} = Instruction.new(action: BasicAction)
      assert instruction.action == BasicAction
      assert instruction.params == %{}
      assert instruction.context == %{}
      refute Map.has_key?(instruction, :id)
    end

    test "creates an instruction with all fields" do
      assert {:ok, instruction} =
               Instruction.new(%{
                 action: BasicAction,
                 params: [value: 42],
                 context: [request_id: "req-1"]
               })

      assert instruction.action == BasicAction
      assert instruction.params == %{value: 42}
      assert instruction.context == %{request_id: "req-1"}
    end

    test "normalizes nil params and context" do
      assert {:ok, instruction} =
               Instruction.new(%{
                 action: BasicAction,
                 params: nil,
                 context: nil
               })

      assert instruction.params == %{}
      assert instruction.context == %{}
    end

    test "rejects missing and invalid action values" do
      assert {:error, :missing_action} = Instruction.new(%{params: %{value: 1}})
      assert {:error, :invalid_action} = Instruction.new(%{action: "not_a_module"})
      assert {:error, :invalid_action} = Instruction.new(%{action: nil})
    end

    test "rejects invalid params and context" do
      assert {:error, %Jido.Action.Error.ExecutionFailureError{}} =
               Instruction.new(action: BasicAction, params: ["not", "keyword"])

      assert {:error, %Jido.Action.Error.ExecutionFailureError{}} =
               Instruction.new(action: BasicAction, context: ["not", "keyword"])

      assert {:error, %Jido.Action.Error.ExecutionFailureError{message: params_message}} =
               Instruction.new(action: BasicAction, params: 123)

      assert params_message =~ "Invalid params format"

      assert {:error, %Jido.Action.Error.ExecutionFailureError{message: context_message}} =
               Instruction.new(action: BasicAction, context: 123)

      assert context_message =~ "Invalid context format"
    end

    test "does not accept tuple instruction shims" do
      assert {:error, :missing_action} = Instruction.new({BasicAction, %{value: 1}})
    end
  end

  describe "new!/1" do
    test "returns the instruction on success" do
      instruction = Instruction.new!(action: BasicAction, params: %{value: 7})
      assert instruction.action == BasicAction
      assert instruction.params == %{value: 7}
    end

    test "raises on invalid input" do
      assert_raise Jido.Action.Error.InvalidInputError, fn ->
        Instruction.new!(params: %{value: 1})
      end
    end

    test "raises underlying exception errors" do
      assert_raise Jido.Action.Error.ExecutionFailureError, ~r/Invalid params format/, fn ->
        Instruction.new!(action: BasicAction, params: 123)
      end
    end
  end
end
