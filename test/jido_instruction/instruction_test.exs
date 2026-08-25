defmodule JidoActionTest.InstructionTest do
  use ExUnit.Case, async: true

  alias Jido.Instruction
  alias JidoActionTest.ExecFixtures.MathFlow

  alias JidoActionTest.TestActions.{
    Add,
    BasicAction,
    MissingRun,
    MissingValidateOutput,
    MissingValidateParams
  }

  describe "new/1" do
    test "creates an instruction with defaults" do
      assert {:ok, instruction} = Instruction.new(action: BasicAction)
      assert instruction.action == BasicAction
      assert instruction.params == %{}
      assert instruction.context == %{}
      assert instruction.metadata == %{}
    end

    test "creates an instruction with all fields" do
      assert {:ok, instruction} =
               Instruction.new(%{
                 action: BasicAction,
                 params: [value: 42],
                 context: [request_id: "req-1"],
                 metadata: [source: %{name: "api"}, tags: ["new"]]
               })

      assert instruction.action == BasicAction
      assert instruction.params == %{value: 42}
      assert instruction.context == %{request_id: "req-1"}
      assert instruction.metadata == %{source: %{name: "api"}, tags: ["new"]}
    end

    test "normalizes nil invocation maps" do
      assert {:ok, instruction} =
               Instruction.new(%{
                 action: BasicAction,
                 params: nil,
                 context: nil,
                 metadata: nil
               })

      assert instruction.params == %{}
      assert instruction.context == %{}
      assert instruction.metadata == %{}
    end

    test "stores Flow module targets" do
      assert {:ok, instruction} =
               Instruction.new(
                 action: MathFlow,
                 params: %{value: 2},
                 context: %{tenant: "acme"},
                 metadata: %{request: %{id: "req-1"}}
               )

      assert instruction.action == MathFlow
      assert instruction.params == %{value: 2}
      assert instruction.context == %{tenant: "acme"}
      assert instruction.metadata == %{request: %{id: "req-1"}}
    end

    test "stores runtime Flow values without conversion" do
      flow = MathFlow.flow()

      assert {:ok, instruction} =
               Instruction.new(
                 action: flow,
                 params: %{value: 2},
                 metadata: %{origin: :runtime}
               )

      assert instruction.action === flow
      assert instruction.metadata == %{origin: :runtime}
    end

    test "returns structured errors for missing and invalid targets" do
      assert {:error, %Jido.Action.Error.InvalidInputError{details: missing_details}} =
               Instruction.new(%{params: %{value: 1}})

      assert missing_details == %{field: :action, reason: :missing}

      for target <- ["not_a_module", nil] do
        assert {:error, %Jido.Action.Error.ConfigurationError{details: details}} =
                 Instruction.new(%{action: target})

        assert details.executable == target
      end
    end

    test "rejects invalid invocation maps" do
      assert {:error, %Jido.Action.Error.InvalidInputError{} = params_error} =
               Instruction.new(action: BasicAction, params: ["not", "keyword"])

      refute Jido.Action.Error.retryable?(params_error)

      assert {:error, %Jido.Action.Error.InvalidInputError{}} =
               Instruction.new(action: BasicAction, context: ["not", "keyword"])

      assert {:error, %Jido.Action.Error.InvalidInputError{message: params_message}} =
               Instruction.new(action: BasicAction, params: 123)

      assert params_message =~ "Invalid params format"

      assert {:error, %Jido.Action.Error.InvalidInputError{message: context_message}} =
               Instruction.new(action: BasicAction, context: 123)

      assert context_message =~ "Invalid context format"

      assert {:error, %Jido.Action.Error.InvalidInputError{message: metadata_message}} =
               Instruction.new(action: BasicAction, metadata: 123)

      assert metadata_message =~ "Invalid metadata format"
    end

    test "does not accept tuple instruction shims" do
      assert {:error, %Jido.Action.Error.InvalidInputError{details: details}} =
               Instruction.new({BasicAction, %{value: 1}})

      assert details.reason == :invalid_attributes
    end

    test "returns a validation error for malformed list attributes" do
      assert {:error, %Jido.Action.Error.InvalidInputError{message: message}} =
               Instruction.new([:not_keyword])

      assert message == "Invalid instruction configuration"
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
      assert instruction.metadata == %{}
    end

    test "keeps nested metadata when it normalizes an instruction" do
      metadata = %{
        request: %{id: "req-1", source: %{name: "api"}},
        tags: ["flow", "priority"]
      }

      base =
        Instruction.new!(
          action: MathFlow.flow(),
          params: %{value: 1},
          context: %{trace_id: "base"},
          metadata: metadata
        )

      instruction = Instruction.normalize!(base, %{value: 2}, %{tenant: "acme"})

      assert instruction.action === base.action
      assert instruction.params == %{value: 2}
      assert instruction.context == %{trace_id: "base", tenant: "acme"}
      assert instruction.metadata === metadata
    end

    test "builds from a runtime Flow target" do
      flow = MathFlow.flow()
      instruction = Instruction.normalize!(flow, %{value: 2}, %{tenant: "acme"})

      assert instruction.action === flow
      assert instruction.params == %{value: 2}
      assert instruction.context == %{tenant: "acme"}
      assert instruction.metadata == %{}
    end

    test "normalizes nil params and context" do
      instruction = Instruction.normalize!(Add, nil, nil)

      assert instruction.params == %{}
      assert instruction.context == %{}
    end

    test "rejects invalid normalization inputs" do
      assert_raise Jido.Action.Error.ConfigurationError, ~r/unknown executable/, fn ->
        Instruction.normalize!(nil)
      end

      invalid = %Instruction{action: "not executable"}

      assert_raise Jido.Action.Error.InvalidInputError,
                   ~r/Invalid instruction configuration/,
                   fn -> Instruction.normalize!(invalid) end

      assert_raise ArgumentError, ~r/expected params to be a map or keyword list/, fn ->
        apply(Instruction, :normalize!, [Add, 123])
      end

      assert_raise ArgumentError, ~r/expected a map or keyword list/, fn ->
        Instruction.normalize!(Add, [:not, :keyword])
      end

      assert_raise ArgumentError, ~r/expected context to be a map or keyword list/, fn ->
        apply(Instruction, :normalize!, [Add, %{}, 123])
      end
    end
  end

  describe "validate_action_contract/1" do
    test "delegates target validation to Jido.Executable" do
      assert :ok = Instruction.validate_action_contract(Add)
      assert :ok = Instruction.validate_action_contract(MathFlow)
      assert :ok = Instruction.validate_action_contract(MathFlow.flow())

      assert {:error, missing_run} = Instruction.validate_action_contract(MissingRun)
      assert missing_run.details.reason == "missing run/2"

      assert {:error, missing_params} =
               Instruction.validate_action_contract(MissingValidateParams)

      assert missing_params.details.reason == "missing validate_params/1"

      assert {:error, missing_output} =
               Instruction.validate_action_contract(MissingValidateOutput)

      assert missing_output.details.reason == "missing validate_output/1"

      assert {:error, unloaded} =
               Instruction.validate_action_contract(Module.concat(__MODULE__, Missing))

      assert unloaded.message =~ "unknown executable"

      assert {:error, invalid} = Instruction.validate_action_contract("not a module")
      assert invalid.message =~ "unknown executable"
    end

    test "raises action contract errors" do
      assert_raise ArgumentError, ~r/not a valid Jido action/, fn ->
        Instruction.validate_action_contract!(MissingRun)
      end
    end
  end

  describe "new!/1" do
    test "returns the instruction on success" do
      instruction = Instruction.new!(action: BasicAction, params: %{value: 7})
      assert instruction.action == BasicAction
      assert instruction.params == %{value: 7}
      assert instruction.metadata == %{}
    end

    test "raises on invalid input" do
      assert_raise Jido.Action.Error.InvalidInputError, fn ->
        Instruction.new!(params: %{value: 1})
      end
    end

    test "raises underlying exception errors" do
      assert_raise Jido.Action.Error.InvalidInputError, ~r/Invalid params format/, fn ->
        Instruction.new!(action: BasicAction, params: 123)
      end
    end
  end
end
