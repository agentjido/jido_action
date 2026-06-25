defmodule Jido.ExecTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Action.Error.{ConfigurationError, ExecutionFailureError, InvalidInputError}
  alias Jido.Exec
  alias Jido.Flow
  alias Jido.Flow.{Builder, Node, Ref}
  alias Jido.Instruction
  alias JidoTest.FlowFixtures

  alias JidoTest.TestActions.{
    Add,
    AtomErrorAction,
    ContextEcho,
    Divide,
    EchoParamsAction,
    ErrorAction,
    ErrorWithExtrasAction,
    ExceptionErrorAction,
    ExtrasAction,
    OutputEnvelopeAction,
    ThrowingAction,
    TupleErrorAction,
    UnsupportedResult
  }

  defmodule StructInput do
    @moduledoc false
    defstruct [:value]
  end

  describe "run/3 with action modules" do
    test "executes a leaf action with input and context validation" do
      assert {:ok, %{value: 6}} = Exec.run(Add, %{value: 5}, %{trace_id: "trace"})
    end

    test "normalizes keyword input and context for leaf actions" do
      assert {:ok, %{value: 6}} = Exec.run(Add, [value: 5], trace_id: "trace")
    end

    test "preserves action extras from leaf actions" do
      assert {:ok, %{value: 5}, %{trace_id: "trace"}} =
               Exec.run(ExtrasAction, %{value: 5}, %{trace_id: "trace"})
    end

    test "validates explicit output envelopes from leaf actions" do
      assert {:ok, %Jido.Action.Output{kind: :raw, value: %{value: 3}, meta: %{source: :test}}} =
               Exec.run(OutputEnvelopeAction, %{value: 3}, %{})
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

    test "normalizes three-element action error tuples" do
      assert {:error, %ExecutionFailureError{message: message, details: details}} =
               Exec.run(ErrorWithExtrasAction, %{reason: :bad_with_extras}, %{})

      assert message == "bad_with_extras"
      assert details.reason == :bad_with_extras
    end

    test "preserves exception action errors returned by leaf actions" do
      assert {:error, %ExecutionFailureError{message: message, details: details}} =
               Exec.run(ExceptionErrorAction, %{}, %{})

      assert message == "already wrapped"
      assert details.source == :test
    end

    test "normalizes atom and tuple action error reasons" do
      assert {:error, %ExecutionFailureError{message: "bad_atom"}} =
               Exec.run(AtomErrorAction, %{}, %{})

      assert {:error, %ExecutionFailureError{message: "{:bad, :tuple}"}} =
               Exec.run(TupleErrorAction, %{}, %{})
    end

    test "converts raised leaf action exceptions to execution errors" do
      assert {:error, %ExecutionFailureError{message: message, details: details}} =
               Exec.run(ErrorAction, %{error_type: :runtime}, %{})

      assert message =~ "Runtime error"
      assert details.action == ErrorAction
      assert details.exception == RuntimeError
    end

    test "converts unsupported action result shapes to execution errors" do
      assert {:error, %ExecutionFailureError{message: message, details: details}} =
               Exec.run(UnsupportedResult)

      assert message =~ "action returned an unsupported result"
      assert details.action == UnsupportedResult
      assert details.result == :not_a_result_tuple
    end

    test "converts thrown action values to execution errors" do
      assert {:error, %ExecutionFailureError{message: message, details: details}} =
               Exec.run(ThrowingAction)

      assert message =~ "action throw"
      assert details.action == ThrowingAction
      assert details.reason == :thrown_value
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

    test "returns validation errors when instruction call-site input is invalid" do
      instruction = Instruction.new!(action: Add)

      assert {:error, %InvalidInputError{message: message}} =
               Exec.run(instruction, :not_params, %{})

      assert message =~ "expected params to be a map or keyword list"
    end
  end

  describe "run/3 with flows" do
    test "executes a Flow artifact" do
      assert {:ok, flow} = Builder.build(FlowFixtures.math_builder())
      assert {:ok, 8} = Exec.run(flow, %{value: 3}, %{})
    end

    test "executes a binding-first Flow artifact with whole-result input" do
      assert {:ok, flow} = Builder.build(FlowFixtures.binding_builder())
      assert {:ok, %{value: 8}} = Exec.run(flow, %{value: 3}, %{})
    end

    test "normalizes nil and keyword input or context for Flow artifacts" do
      assert {:ok, flow} = Builder.build(FlowFixtures.math_builder())

      assert {:ok, 8} = Exec.run(flow, [value: 3], [])

      empty_flow =
        Flow.new!(
          name: "empty_input",
          nodes: [
            Node.new!(name: :constant, action: Add, input: %{value: Ref.value(1)})
          ],
          return: Ref.result(:constant, :value)
        )

      assert {:ok, 2} = Exec.run(empty_flow, nil, nil)
    end

    test "rejects invalid Flow input and context shapes" do
      assert {:ok, flow} = Builder.build(FlowFixtures.math_builder())

      assert {:error, %InvalidInputError{message: message}} = Exec.run(flow, :not_input, %{})
      assert message =~ "input must be a map or keyword list"

      assert {:error, %InvalidInputError{message: message}} = Exec.run(flow, %{}, :not_context)
      assert message =~ "context must be a map or keyword list"

      assert {:error, %InvalidInputError{message: message}} = Exec.run(flow, [:not_keyword], %{})
      assert message =~ "expected a map or keyword list"
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
            step(:add_one, unquote(Add), %{value: input(:value), amount: value(1)})

            step(
              :double,
              unquote(JidoTest.TestActions.Multiply),
              %{
                value: result(:add_one, :value),
                amount: value(2)
              }
            )

            return(result(:double, :value))
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

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Exec.run(flow, %{value: 3}, %{trace_id: "trace"})

      assert message =~ "expected integer"
      assert details.phase == :flow_output
      assert details.context == "Flow output"
    end

    test "accepts scalar Flow output schemas when the return value matches" do
      flow =
        Flow.new!(
          name: "scalar_output",
          output_schema: Zoi.integer(),
          nodes: [
            Node.new!(name: :add_one, action: Add, input: %{value: Ref.input(:value)})
          ],
          return: Ref.result(:add_one, :value)
        )

      assert {:ok, 4} = Exec.run(flow, %{value: 3}, %{})
    end

    test "validates Flow input schema before compiling execution" do
      flow =
        Flow.new!(
          name: "input_schema",
          schema: Zoi.object(%{value: Zoi.integer()}),
          nodes: [
            Node.new!(name: :echo, action: ContextEcho, input: %{value: Ref.input(:value)})
          ],
          return: Ref.result(:echo, :value)
        )

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Exec.run(flow, %{value: "bad"}, %{trace_id: "trace"})

      assert message =~ "expected integer"
      assert details.phase == :flow_input
      assert details.context == "Flow"
    end

    test "validates scalar Flow input schemas against map input" do
      flow =
        Flow.new!(
          name: "scalar_input_schema",
          schema: Zoi.integer(),
          nodes: [
            Node.new!(name: :add_one, action: Add, input: %{value: Ref.input(:value)})
          ],
          return: Ref.result(:add_one, :value)
        )

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Exec.run(flow, %{value: 3}, %{})

      assert message =~ "expected integer"
      assert details.phase == :flow_input
      assert details.context == "Flow"
    end

    test "keeps unknown flow input fields after object schema validation" do
      flow =
        Flow.new!(
          name: "object_schema_input",
          schema: Zoi.object(%{value: Zoi.integer()}),
          nodes: [
            Node.new!(
              name: :echo,
              action: EchoParamsAction,
              input: %{value: Ref.input(:value), extra: Ref.input(:extra)}
            )
          ],
          return: Ref.result(:echo, :extra)
        )

      assert {:ok, "kept"} = Exec.run(flow, %{value: 3, extra: "kept"}, %{})
    end

    test "keeps unknown flow input fields after struct schema validation" do
      flow =
        Flow.new!(
          name: "struct_schema_input",
          schema: Zoi.struct(StructInput, [value: Zoi.integer()], coerce: true),
          nodes: [
            Node.new!(
              name: :echo,
              action: EchoParamsAction,
              input: %{value: Ref.input(:value), extra: Ref.input(:extra)}
            )
          ],
          return: Ref.result(:echo, :extra)
        )

      assert {:ok, "kept"} = Exec.run(flow, %{value: 3, extra: "kept"}, %{})
    end

    test "handles map schemas without explicit field lists" do
      flow =
        Flow.new!(
          name: "dynamic_map_schema_input",
          schema: Zoi.map(Zoi.string(), Zoi.integer()),
          nodes: [
            Node.new!(
              name: :echo,
              action: EchoParamsAction,
              input: %{"value" => Ref.input("value")}
            )
          ],
          return: Ref.result(:echo, "value")
        )

      assert {:ok, 3} = Exec.run(flow, %{"value" => 3}, %{})
    end
  end

  test "rejects unknown executable values with a configuration error" do
    assert {:error, %ConfigurationError{message: message}} = Exec.run(:not_a_real_executable)
    assert message =~ "unknown executable"
  end

  test "rejects unsupported executable values with a configuration error" do
    assert {:error, %ConfigurationError{message: message, details: details}} =
             Exec.run("not executable")

    assert message =~ "unknown executable"
    assert details.executable == "not executable"
  end
end
