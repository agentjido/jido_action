defmodule JidoActionTest.InstructionTest do
  use ExUnit.Case, async: true

  alias Jido.Instruction
  alias JidoActionTest.Fixtures.MathFlow

  alias JidoActionTest.Fixtures.Actions.{Add, BasicAction}

  describe "new/1" do
    test "exposes only the four call-data fields" do
      assert Instruction.new!(target: BasicAction)
             |> Map.from_struct()
             |> Map.keys()
             |> Enum.sort() ==
               [:context, :metadata, :params, :target]
    end

    test "rejects removed fields in map and keyword constructors even when empty" do
      for {field, value} <- [
            action: BasicAction,
            flow: MathFlow,
            opts: [timeout: 10],
            action: nil,
            flow: nil,
            opts: [],
            opts: nil,
            id: "old"
          ],
          base <- [%{}, %{target: BasicAction}],
          attrs <- [Map.put(base, field, value), Map.to_list(Map.put(base, field, value))] do
        assert {:error, %Jido.Action.Error.InvalidInputError{details: details} = error} =
                 Instruction.new(attrs)

        assert details == %{fields: [field], reason: :removed_instruction_fields}
        refute Jido.Action.Error.retryable?(error)

        assert_raise Jido.Action.Error.InvalidInputError, error.message, fn ->
          Instruction.new!(attrs)
        end
      end
    end

    test "reports all removed fields in stable order" do
      attrs = %{target: BasicAction, opts: [], flow: nil, action: nil, id: "old"}

      assert {:error, %Jido.Action.Error.InvalidInputError{details: details}} =
               Instruction.new(attrs)

      assert details == %{
               fields: [:id, :action, :flow, :opts],
               reason: :removed_instruction_fields
             }
    end

    test "removed fields cannot appear in struct literals" do
      for field <- [:action, :flow, :opts] do
        literal = {:%, [], [Instruction, {:%{}, [], [{field, nil}]}]}
        assert_raise KeyError, fn -> Code.eval_quoted(literal) end
      end
    end

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
    test "uses shallow call-site overrides and preserves caller metadata" do
      metadata = %{timeout: 0, task_supervisor: :description_only, nested: %{id: "one"}}

      base =
        Instruction.new!(
          target: Add,
          params: %{nested: %{old: true}, keep: 1},
          context: %{nested: %{old: true}, keep: 2},
          metadata: metadata
        )

      normalized = Instruction.normalize!(base, [nested: %{new: true}], nested: nil)

      assert normalized.params == %{nested: %{new: true}, keep: 1}
      assert normalized.context == %{nested: nil, keep: 2}
      assert normalized.metadata === metadata
    end

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
