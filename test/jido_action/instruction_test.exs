defmodule Jido.InstructionTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Exec
  alias Jido.Instruction
  alias JidoTest.TestActions.BasicAction
  alias JidoTest.TestActions.EchoAction
  alias JidoTest.TestActions.NoSchema

  @moduletag :capture_log

  describe "new/1" do
    test "creates an instruction with defaults" do
      assert {:ok, instruction} = Instruction.new(action: BasicAction)
      assert instruction.action == BasicAction
      assert instruction.params == %{}
      assert instruction.context == %{}
      assert instruction.opts == []
      assert is_binary(instruction.id)
    end

    test "creates an instruction with all fields" do
      assert {:ok, instruction} =
               Instruction.new(%{
                 id: "instruction-1",
                 action: BasicAction,
                 params: [value: 42],
                 context: [request_id: "req-1"],
                 opts: [timeout: 1_000]
               })

      assert instruction.id == "instruction-1"
      assert instruction.action == BasicAction
      assert instruction.params == %{value: 42}
      assert instruction.context == %{request_id: "req-1"}
      assert instruction.opts == [timeout: 1_000]
    end

    test "rejects missing and invalid action values" do
      assert {:error, :missing_action} = Instruction.new(%{params: %{value: 1}})
      assert {:error, :invalid_action} = Instruction.new(%{action: "not_a_module"})
      assert {:error, :invalid_action} = Instruction.new(%{action: nil})
    end

    test "rejects invalid params, context, and opts" do
      assert {:error, %Jido.Action.Error.ExecutionFailureError{}} =
               Instruction.new(action: BasicAction, params: ["not", "keyword"])

      assert {:error, %Jido.Action.Error.ExecutionFailureError{}} =
               Instruction.new(action: BasicAction, context: ["not", "keyword"])

      assert {:error, %Jido.Action.Error.ExecutionFailureError{}} =
               Instruction.new(action: BasicAction, opts: %{timeout: 1_000})
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
  end

  describe "normalize_single/3" do
    test "normalizes an instruction struct and merges context and opts" do
      instruction = %Instruction{
        action: BasicAction,
        params: %{value: 1},
        context: %{local: true},
        opts: [timeout: 500]
      }

      assert {:ok, normalized} =
               Instruction.normalize_single(instruction, %{request_id: "req-1"}, timeout: 1_000)

      assert normalized.action == BasicAction
      assert normalized.params == %{value: 1}
      assert normalized.context == %{local: true, request_id: "req-1"}
      assert normalized.opts == [timeout: 1_000]
      assert is_binary(normalized.id)
    end

    test "normalizes a bare action module" do
      assert {:ok, instruction} = Instruction.normalize_single(BasicAction)
      assert instruction.action == BasicAction
      assert instruction.params == %{}
      assert instruction.context == %{}
    end

    test "normalizes action tuples" do
      assert {:ok, instruction} =
               Instruction.normalize_single(
                 {BasicAction, [value: 42], [local: true], [timeout: 250]},
                 %{request_id: "req-1"},
                 timeout: 1_000
               )

      assert instruction.action == BasicAction
      assert instruction.params == %{value: 42}
      assert instruction.context == %{local: true, request_id: "req-1"}
      assert instruction.opts == [timeout: 1_000]
    end

    test "rejects invalid input" do
      assert {:error, %Jido.Action.Error.ExecutionFailureError{}} =
               Instruction.normalize_single(123)

      assert {:error, %Jido.Action.Error.ExecutionFailureError{}} =
               Instruction.normalize_single({BasicAction, "invalid"})
    end
  end

  describe "normalize/3" do
    test "normalizes a single instruction into a list" do
      assert {:ok, [instruction]} = Instruction.normalize({BasicAction, %{value: 1}})
      assert instruction.action == BasicAction
      assert instruction.params == %{value: 1}
    end

    test "normalizes a flat list of mixed instruction inputs" do
      assert {:ok, [first, second, third]} =
               Instruction.normalize(
                 [
                   BasicAction,
                   {NoSchema, %{data: "test"}},
                   %Instruction{action: BasicAction, params: %{value: 5}}
                 ],
                 %{request_id: "req-1"}
               )

      assert first.action == BasicAction
      assert first.context == %{request_id: "req-1"}
      assert second.action == NoSchema
      assert second.params == %{data: "test"}
      assert third.params == %{value: 5}
      assert third.context == %{request_id: "req-1"}
    end

    test "rejects nested lists" do
      assert {:error, %Jido.Action.Error.ExecutionFailureError{}} =
               Instruction.normalize([BasicAction, [NoSchema]])
    end
  end

  describe "normalize!/3" do
    test "returns normalized instructions" do
      assert [%Instruction{action: BasicAction, params: %{value: 1}}] =
               Instruction.normalize!({BasicAction, %{value: 1}})
    end

    test "raises on invalid input" do
      assert_raise Jido.Action.Error.ExecutionFailureError, fn ->
        Instruction.normalize!(123)
      end
    end
  end

  describe "validate_allowed_actions/2" do
    test "accepts allowed actions" do
      instructions = [
        %Instruction{action: BasicAction},
        %Instruction{action: NoSchema}
      ]

      assert :ok = Instruction.validate_allowed_actions(instructions, [BasicAction, NoSchema])
    end

    test "rejects disallowed actions" do
      assert {:error, %Jido.Action.Error.ConfigurationError{message: message}} =
               Instruction.validate_allowed_actions(%Instruction{action: NoSchema}, [BasicAction])

      assert message =~ "Actions not allowed"
      assert message =~ "NoSchema"
    end
  end

  describe "Exec.run/4" do
    test "executes an instruction" do
      instruction =
        Instruction.new!(
          action: BasicAction,
          params: %{value: 42},
          context: %{request_id: "req-1"},
          opts: [timeout: 1_000]
        )

      assert {:ok, %{value: 42}} = Exec.run(instruction)
    end

    test "merges params, context, and opts overrides" do
      instruction =
        Instruction.new!(
          action: EchoAction,
          params: %{from_instruction: true, override: "instruction"},
          context: %{local: true, override: "instruction"},
          opts: [timeout: 1_000]
        )

      assert {:ok, %{params: params, context: context}} =
               Exec.run(
                 instruction,
                 %{from_call: true, override: "call"},
                 %{request_id: "req-1", override: "call"},
                 timeout: 0
               )

      assert params == %{from_instruction: true, from_call: true, override: "call"}
      assert context == %{local: true, request_id: "req-1", override: "call"}
    end
  end

  describe "Exec.run_async/4" do
    test "executes an instruction asynchronously" do
      instruction = Instruction.new!(action: BasicAction, params: %{value: 10})

      instruction
      |> Exec.run_async()
      |> Exec.await(5_000)
      |> then(fn result -> assert {:ok, %{value: 10}} = result end)
    end
  end
end
