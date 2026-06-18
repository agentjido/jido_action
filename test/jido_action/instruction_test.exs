defmodule Jido.InstructionTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Instruction
  alias JidoTest.TestActions.{Add, BasicAction, MissingRun, MissingValidateOutput}

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

  describe "normalize!/3" do
    test "builds an instruction from an action module" do
      instruction = Instruction.normalize!(Add, [amount: 2], trace_id: "trace")

      assert %Instruction{action: Add, params: %{amount: 2}, context: %{trace_id: "trace"}} =
               instruction
    end

    test "builds from an instruction and merges call-site overrides" do
      base =
        Instruction.new!(
          action: Add,
          params: %{amount: 1, value: 5},
          context: %{trace_id: "base"}
        )

      instruction =
        Instruction.normalize!(
          base,
          %{amount: 3},
          %{tenant_id: "tenant"}
        )

      assert instruction.action == Add
      assert instruction.params == %{amount: 3, value: 5}
      assert instruction.context == %{trace_id: "base", tenant_id: "tenant"}
    end

    test "normalizes nil params and context" do
      instruction = Instruction.normalize!(Add, nil, nil)

      assert instruction.params == %{}
      assert instruction.context == %{}
    end

    test "rejects invalid normalization inputs" do
      assert_raise ArgumentError, ~r/expected an action module or %Jido.Instruction{}/, fn ->
        Instruction.normalize!(nil)
      end

      assert_raise ArgumentError, ~r/expected params to be a map or keyword list/, fn ->
        Instruction.normalize!(Add, 123)
      end

      assert_raise ArgumentError, ~r/expected a map or keyword list/, fn ->
        Instruction.normalize!(Add, [:not, :keyword])
      end

      assert_raise ArgumentError, ~r/expected context to be a map or keyword list/, fn ->
        Instruction.normalize!(Add, %{}, 123)
      end
    end
  end

  describe "validate_action_contract/1" do
    test "validates action callback contracts" do
      assert :ok = Instruction.validate_action_contract(Add)

      assert {:error, missing_run} = Instruction.validate_action_contract(MissingRun)
      assert missing_run.details.reason == "missing run/2"

      assert {:error, missing_output} =
               Instruction.validate_action_contract(MissingValidateOutput)

      assert missing_output.details.reason == "missing validate_output/1"

      assert {:error, unloaded} =
               Instruction.validate_action_contract(Module.concat(__MODULE__, Missing))

      assert unloaded.message == "action module could not be loaded"

      assert {:error, invalid} = Instruction.validate_action_contract("not a module")
      assert invalid.message =~ "expected an action module"
    end

    test "raises action contract errors" do
      assert_raise ArgumentError, ~r/not a valid Jido action/, fn ->
        Instruction.validate_action_contract!(MissingRun)
      end
    end
  end

  describe "derive_action_name/1" do
    test "derives action names from module names" do
      assert Instruction.derive_action_name(Add) == :add
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
