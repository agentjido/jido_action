defmodule Jido.Flow.CompilerTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Action.Error.{ConfigurationError, ExecutionFailureError, InvalidInputError}
  alias Jido.Action.Output
  alias Jido.Flow
  alias Jido.Flow.{Compiler, Node, Ref}
  alias JidoTest.FlowFixtures

  alias JidoTest.TestActions.{
    Add,
    AtomValidationAction,
    ContextEcho,
    InvalidOutput,
    Multiply,
    OutputEnvelopeAction,
    ThrowingAction,
    UnsupportedResult
  }

  alias Runic.Workflow

  describe "compile/1" do
    test "compiles a one-step flow to a Runic workflow with a named action component" do
      flow = one_step_flow()

      assert {:ok, workflow} = Flow.compile(flow)
      assert %Workflow{} = workflow
      assert Workflow.get_component(workflow, :add_one)
      assert workflow |> Workflow.steps() |> Enum.map(& &1.name) == [:add_one]
    end

    test "compiles the math flow in dependency order" do
      assert {:ok, flow} = Jido.Flow.Builder.build(FlowFixtures.math_builder())
      assert {:ok, workflow} = Flow.compile(flow)

      assert component_order(workflow) == [:add_one, :double]
    end

    test "rejects dependency graphs that cannot be topologically ordered" do
      flow =
        Flow.new!(
          name: "cycle",
          nodes: [
            Node.new!(
              name: :first,
              action: Add,
              input: %{value: Ref.result(:second, :value), amount: Ref.value(1)}
            ),
            Node.new!(
              name: :second,
              action: Multiply,
              input: %{value: Ref.result(:first, :value), amount: Ref.value(2)}
            )
          ],
          return: Ref.result(:second, :value)
        )

      assert {:error, %ConfigurationError{message: message, details: details}} =
               Flow.compile(flow)

      assert message =~ "dependency graph cannot be topologically ordered"
      assert Enum.sort(details.nodes) == [:first, :second]
    end

    test "serializes independent branches deliberately for the first milestone" do
      flow =
        Flow.new!(
          name: "serialized",
          nodes: [
            Node.new!(name: :first, action: Add, input: %{value: Ref.input(:value)}),
            Node.new!(name: :second, action: Add, input: %{value: Ref.input(:value)})
          ],
          return: Ref.result(:second, :value)
        )

      assert {:ok, workflow} = Flow.compile(flow)
      assert component_order(workflow) == [:first, :second]
    end
  end

  describe "run/3" do
    test "executes the compiled workflow and extracts the declared return" do
      assert {:ok, flow} = Jido.Flow.Builder.build(FlowFixtures.math_builder())
      assert {:ok, 8} = Compiler.run(flow, %{value: 3}, %{})
    end

    test "rejects non-map input or context" do
      flow = one_step_flow()

      assert {:error, %InvalidInputError{message: message}} = Compiler.run(flow, [], %{})
      assert message =~ "flow input and context must be maps"

      assert {:error, %InvalidInputError{message: message}} = Compiler.run(flow, %{}, [])
      assert message =~ "flow input and context must be maps"
    end

    test "resolves atom paths from atom or string keyed input maps" do
      flow = one_step_flow()

      assert {:ok, 4} = Compiler.run(flow, %{value: 3}, %{})
      assert {:ok, 4} = Compiler.run(flow, %{"value" => 3}, %{})
    end

    test "passes runtime context to action invocations without changing the canonical map" do
      flow =
        Flow.new!(
          name: "context",
          nodes: [
            Node.new!(name: :echo, action: ContextEcho, input: %{value: Ref.input(:value)})
          ],
          return: Ref.result(:echo, :trace_id)
        )

      canonical = Flow.to_map(flow)

      assert {:ok, "trace-1"} = Compiler.run(flow, %{value: 3}, %{trace_id: "trace-1"})
      assert {:ok, "trace-2"} = Compiler.run(flow, %{value: 3}, %{trace_id: "trace-2"})
      assert Flow.to_map(flow) == canonical
    end

    test "returns existing action validation errors for invalid step input" do
      assert {:ok, flow} = Jido.Flow.Builder.build(FlowFixtures.math_builder())

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Compiler.run(flow, %{value: "bad"}, %{})

      assert message =~ "expected integer"
      assert details.phase == :step_input
      assert details.node == :add_one
      assert details.action == Add
    end

    test "returns existing action validation errors for invalid step output" do
      flow =
        Flow.new!(
          name: "invalid_output",
          nodes: [
            Node.new!(name: :invalid, action: InvalidOutput, input: %{value: Ref.input(:value)})
          ],
          return: Ref.result(:invalid, :value)
        )

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Compiler.run(flow, %{value: 3}, %{})

      assert message =~ "expected integer"
      assert details.phase == :step_output
      assert details.node == :invalid
      assert details.action == InvalidOutput
    end

    test "returns execution errors for unsupported action result tuples" do
      flow =
        Flow.new!(
          name: "unsupported_result",
          nodes: [
            Node.new!(name: :bad, action: UnsupportedResult)
          ],
          return: Ref.result(:bad)
        )

      assert {:error, %ExecutionFailureError{message: message, details: details}} =
               Compiler.run(flow, %{}, %{})

      assert message =~ "action returned an unsupported result"
      assert details.phase == :step_execution
      assert details.node == :bad
      assert details.action == UnsupportedResult
      assert details.result == :not_a_result_tuple
    end

    test "returns execution errors for thrown action values" do
      flow =
        Flow.new!(
          name: "throwing",
          nodes: [
            Node.new!(name: :throwing, action: ThrowingAction)
          ],
          return: Ref.result(:throwing)
        )

      assert {:error, %ExecutionFailureError{message: message, details: details}} =
               Compiler.run(flow, %{}, %{})

      assert message =~ "action throw"
      assert details.phase == :step_execution
      assert details.node == :throwing
      assert details.reason == :thrown_value
    end

    test "passes explicit output envelopes through output validation" do
      flow =
        Flow.new!(
          name: "output_envelope",
          nodes: [
            Node.new!(
              name: :envelope,
              action: OutputEnvelopeAction,
              input: %{value: Ref.input(:value)}
            )
          ],
          return: Ref.result(:envelope)
        )

      assert {:ok, %Output{kind: :raw, value: %{value: 3}, meta: %{source: :test}}} =
               Compiler.run(flow, %{value: 3}, %{})
    end

    test "normalizes non-exception validation failures with step metadata" do
      flow =
        Flow.new!(
          name: "atom_validation",
          nodes: [
            Node.new!(name: :bad_params, action: AtomValidationAction)
          ],
          return: Ref.result(:bad_params)
        )

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Compiler.run(flow, %{}, %{})

      assert message == "bad_params"
      assert details.phase == :step_input
      assert details.node == :bad_params
      assert details.action == AtomValidationAction
      assert details.reason == :bad_params
    end
  end

  defp one_step_flow do
    Flow.new!(
      name: "one_step",
      nodes: [
        Node.new!(
          name: :add_one,
          action: Add,
          input: %{value: Ref.input(:value), amount: Ref.value(1)}
        )
      ],
      return: Ref.result(:add_one, :value)
    )
  end

  defp component_order(workflow) do
    workflow.build_log
    |> Enum.reverse()
    |> Enum.map(& &1.name)
  end
end
