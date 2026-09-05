defmodule JidoActionTest.InstructionTest do
  # Negative log assertions must not capture warnings from concurrent Exec tests.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Jido.Instruction
  alias JidoActionTest.Fixtures.MathFlow

  alias JidoActionTest.Fixtures.Actions.{Add, BasicAction}

  describe "new/1" do
    test "creates an instruction with defaults" do
      assert {:ok, instruction} = Instruction.new(target: BasicAction)
      assert instruction.target == BasicAction
      assert instruction.params == %{}
      assert instruction.context == %{}
      assert instruction.metadata == %{}
    end

    test "creates an instruction with all fields" do
      assert {:ok, instruction} =
               Instruction.new(%{
                 target: BasicAction,
                 params: [value: 42],
                 context: [request_id: "req-1"],
                 metadata: [source: %{name: "api"}, tags: ["new"]]
               })

      assert instruction.target == BasicAction
      assert instruction.params == %{value: 42}
      assert instruction.context == %{request_id: "req-1"}
      assert instruction.metadata == %{source: %{name: "api"}, tags: ["new"]}
    end

    test "normalizes nil invocation maps" do
      assert {:ok, instruction} =
               Instruction.new(%{
                 target: BasicAction,
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
                 target: MathFlow,
                 params: %{value: 2},
                 context: %{tenant: "acme"},
                 metadata: %{request: %{id: "req-1"}}
               )

      assert instruction.target == MathFlow
      assert instruction.params == %{value: 2}
      assert instruction.context == %{tenant: "acme"}
      assert instruction.metadata == %{request: %{id: "req-1"}}
    end

    test "stores runtime Flow values without conversion" do
      flow = MathFlow.flow()

      assert {:ok, instruction} =
               Instruction.new(
                 target: flow,
                 params: %{value: 2},
                 metadata: %{origin: :runtime}
               )

      assert instruction.target === flow
      assert instruction.metadata == %{origin: :runtime}
    end

    test "returns structured errors for missing and invalid targets" do
      assert {:error, %Jido.Action.Error.InvalidInputError{details: missing_details}} =
               Instruction.new(%{params: %{value: 1}})

      assert missing_details == %{field: :target, reason: :missing}

      for target <- ["not_a_module", nil] do
        assert {:error, %Jido.Action.Error.ConfigurationError{details: details}} =
                 Instruction.new(%{target: target})

        assert details.executable == target
      end
    end

    test "normalizes typed target aliases" do
      {{:ok, action_instruction}, log} =
        with_log(fn -> Instruction.new(action: BasicAction, params: %{value: 1}) end)

      assert action_instruction.target == BasicAction
      assert action_instruction.action == nil
      assert action_instruction.flow == nil
      assert action_instruction.params == %{value: 1}
      assert log =~ "Jido.Instruction received the deprecated :action field"
      assert log =~ "Use :target instead"

      assert {:ok, flow_instruction} = Instruction.new(flow: MathFlow)
      assert flow_instruction.target == MathFlow
      assert flow_instruction.action == nil
      assert flow_instruction.flow == nil

      flow = MathFlow.flow()
      assert {:ok, runtime_flow_instruction} = Instruction.new(flow: flow)
      assert runtime_flow_instruction.target === flow
    end

    test "rejects target alias kind mismatches" do
      assert {:error, %Jido.Action.Error.InvalidInputError{details: action_details}} =
               Instruction.new(action: MathFlow)

      assert action_details == %{
               actual_kind: :flow,
               expected_kind: :action,
               field: :action,
               target: MathFlow
             }

      assert {:error, %Jido.Action.Error.InvalidInputError{details: flow_details}} =
               Instruction.new(flow: BasicAction)

      assert flow_details == %{
               actual_kind: :action,
               expected_kind: :flow,
               field: :flow,
               target: BasicAction
             }
    end

    test "rejects conflicting target fields" do
      for attrs <- [
            %{target: BasicAction, action: BasicAction},
            %{target: MathFlow, flow: MathFlow},
            %{action: BasicAction, flow: MathFlow}
          ] do
        assert {:error, %Jido.Action.Error.InvalidInputError{details: details}} =
                 Instruction.new(attrs)

        assert details.reason == :conflicting_target_fields
        assert Enum.sort(details.fields) == attrs |> Map.keys() |> Enum.sort()
      end
    end

    test "accepts deprecated opts but still rejects the removed id field" do
      assert {:error, %Jido.Action.Error.InvalidInputError{details: details}} =
               Instruction.new(action: BasicAction, id: "send-1", opts: [timeout: 5_000])

      assert details == %{fields: [:id], reason: :removed_instruction_fields}

      assert {:ok, instruction} =
               Instruction.new(action: BasicAction, opts: [timeout: 5_000])

      assert instruction.target == BasicAction
      assert instruction.opts == [timeout: 5_000]
    end

    test "rejects malformed deprecated opts" do
      assert {:error, %Jido.Action.Error.InvalidInputError{details: details}} =
               Instruction.new(target: BasicAction, opts: [:not_an_option])

      assert details == %{field: :opts, reason: :not_keyword_list}
    end

    test "rejects invalid invocation maps" do
      assert {:error, %Jido.Action.Error.InvalidInputError{} = params_error} =
               Instruction.new(target: BasicAction, params: ["not", "keyword"])

      refute Jido.Action.Error.retryable?(params_error)

      assert {:error, %Jido.Action.Error.InvalidInputError{}} =
               Instruction.new(target: BasicAction, context: ["not", "keyword"])

      assert {:error, %Jido.Action.Error.InvalidInputError{message: params_message}} =
               Instruction.new(target: BasicAction, params: 123)

      assert params_message =~ "Invalid params format"

      assert {:error, %Jido.Action.Error.InvalidInputError{message: context_message}} =
               Instruction.new(target: BasicAction, context: 123)

      assert context_message =~ "Invalid context format"

      assert {:error, %Jido.Action.Error.InvalidInputError{message: metadata_message}} =
               Instruction.new(target: BasicAction, metadata: 123)

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

      assert %Instruction{target: Add, params: %{amount: 2}, context: %{trace_id: "trace"}} =
               instruction
    end

    test "builds from an instruction and merges call-site overrides" do
      base =
        Instruction.new!(
          target: Add,
          params: %{amount: 1, value: 5},
          context: %{trace_id: "base"}
        )

      instruction =
        Instruction.normalize!(
          base,
          %{amount: 3},
          %{tenant_id: "tenant"}
        )

      assert instruction.target == Add
      assert instruction.params == %{amount: 3, value: 5}
      assert instruction.context == %{trace_id: "base", tenant_id: "tenant"}
      assert instruction.metadata == %{}
    end

    test "normalizes a legacy action struct literal and warns" do
      legacy = %Instruction{
        action: Add,
        params: %{amount: 1, value: 5},
        context: %{trace_id: "base"}
      }

      {instruction, log} =
        with_log(fn ->
          Instruction.normalize!(legacy, %{amount: 3}, %{tenant_id: "tenant"})
        end)

      assert instruction.target == Add
      assert instruction.action == nil
      assert instruction.flow == nil
      assert instruction.params == %{amount: 3, value: 5}
      assert instruction.context == %{trace_id: "base", tenant_id: "tenant"}
      assert log =~ "Jido.Instruction received the deprecated :action field"
    end

    test "keeps deprecated opts until Exec consumes them" do
      legacy = %Instruction{action: Add, opts: [timeout: 5_000]}

      {instruction, log} =
        with_log(fn -> Instruction.normalize!(legacy, %{value: 2}, %{}) end)

      assert instruction.target == Add
      assert instruction.action == nil
      assert instruction.opts == [timeout: 5_000]
      assert log =~ "Jido.Instruction received the deprecated :action field"
      refute log =~ "deprecated :opts field"
    end

    test "keeps nested metadata when it normalizes an instruction" do
      metadata = %{
        request: %{id: "req-1", source: %{name: "api"}},
        tags: ["flow", "priority"]
      }

      base =
        Instruction.new!(
          target: MathFlow.flow(),
          params: %{value: 1},
          context: %{trace_id: "base"},
          metadata: metadata
        )

      instruction = Instruction.normalize!(base, %{value: 2}, %{tenant: "acme"})

      assert instruction.target === base.target
      assert instruction.params == %{value: 2}
      assert instruction.context == %{trace_id: "base", tenant: "acme"}
      assert instruction.metadata === metadata
    end

    test "builds from a runtime Flow target" do
      flow = MathFlow.flow()
      instruction = Instruction.normalize!(flow, %{value: 2}, %{tenant: "acme"})

      assert instruction.target === flow
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

      invalid = %Instruction{target: "not executable"}

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

  describe "new!/1" do
    test "returns the instruction on success" do
      instruction = Instruction.new!(target: BasicAction, params: %{value: 7})
      assert instruction.target == BasicAction
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
        Instruction.new!(target: BasicAction, params: 123)
      end
    end
  end
end
