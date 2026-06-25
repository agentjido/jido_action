defmodule Jido.ExecTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Action.Error.{ConfigurationError, ExecutionFailureError, InvalidInputError}
  alias Jido.Exec
  alias Jido.Flow
  alias Jido.Flow.{Builder, Node, Ref}
  alias Jido.Instruction
  alias JidoTest.FlowFixtures
  alias JidoTest.TestActions.{Add, ContextEcho, Divide, ErrorAction}

  describe "run/3 with action modules" do
    test "executes a leaf action with input and context validation" do
      assert {:ok, %{value: 6}} = Exec.run(Add, %{value: 5}, %{trace_id: "trace"})
    end

    test "validates action params before calling run" do
      assert {:error, %InvalidInputError{message: message}} =
               Exec.run(Add, %{value: "bad"}, %{})

      assert message =~ "expected integer"
    end

    test "returns action errors without Runic-specific wrapping" do
      assert {:error, %ExecutionFailureError{message: message}} =
               Exec.run(ErrorAction, %{error_type: :validation}, %{})

      refute message =~ "Runic"
    end
  end

  describe "run/3 with instructions" do
    test "executes an instruction and merges call-site input and context" do
      instruction =
        Instruction.new!(
          action: Add,
          params: %{value: 5, amount: 1},
          context: %{trace_id: "base"}
        )

      assert {:ok, %{value: 8}} =
               Exec.run(instruction, %{amount: 3}, %{tenant_id: "tenant"})
    end
  end

  describe "run/3 with flows" do
    test "executes a Flow artifact" do
      assert {:ok, flow} = Builder.build(FlowFixtures.math_builder())
      assert {:ok, 8} = Exec.run(flow, %{value: 3}, %{})
    end

    test "executes a Flow module and the equivalent Flow artifact with the same result" do
      module = unique_module("ExecMathFlow")

      create_module(
        module,
        quote do
          use Jido.Flow,
            name: "math_flow",
            description: "Adds one and doubles the result"

          flow do
            step(:add_one, unquote(Add), %{value: input(:value), amount: value(1)}, bind: :added)

            step(
              :double,
              unquote(JidoTest.TestActions.Multiply),
              %{
                value: var(:added, :value),
                amount: value(2)
              }, bind: :doubled)

            return(var(:doubled, :value))
          end
        end
      )

      assert Exec.run(module, %{value: 3}, %{}) == Exec.run(module.flow(), %{value: 3}, %{})
      assert {:ok, 8} = Exec.run(module, %{value: 3}, %{})
    end

    test "converts raised action exceptions during Flow execution into execution errors" do
      flow =
        Flow.new!(
          name: "divide",
          nodes: [
            Node.new!(
              name: :divide,
              action: Divide,
              input: %{value: Ref.input(:value), amount: Ref.value(0.0)}
            )
          ],
          return: Ref.result(:divide, :value)
        )

      assert {:error, %ExecutionFailureError{message: message, details: details}} =
               Exec.run(flow, %{value: 5.0}, %{})

      assert message =~ "Cannot divide by zero"
      assert details.node == :divide
      assert details.action == Divide
    end

    test "validates Flow output schema after extracting the declared return" do
      flow =
        Flow.new!(
          name: "context",
          output_schema: Zoi.integer(),
          nodes: [
            Node.new!(name: :echo, action: ContextEcho, input: %{value: Ref.input(:value)})
          ],
          return: Ref.result(:echo, :trace_id)
        )

      assert {:error, %InvalidInputError{message: message}} =
               Exec.run(flow, %{value: 3}, %{trace_id: "trace"})

      assert message =~ "expected integer"
    end
  end

  test "rejects unknown executable values with a configuration error" do
    assert {:error, %ConfigurationError{message: message}} = Exec.run(:not_a_real_executable)
    assert message =~ "unknown executable"
  end
end
