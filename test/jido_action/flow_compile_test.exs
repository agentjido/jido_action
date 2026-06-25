defmodule Jido.FlowCompileTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Action.Error.{ConfigurationError, InvalidInputError}
  alias Jido.Flow
  alias Jido.Flow.{Compiler, Node, Ref}
  alias JidoTest.FlowFixtures
  alias JidoTest.TestActions.{Add, ContextEcho, InvalidOutput, Multiply}
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

      assert {:error, %InvalidInputError{message: message}} =
               Compiler.run(flow, %{value: "bad"}, %{})

      assert message =~ "expected integer"

      assert {:error, %InvalidInputError{details: details}} =
               Compiler.run(flow, %{value: "bad"}, %{})

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

      assert {:error, %InvalidInputError{message: message}} =
               Compiler.run(flow, %{value: 3}, %{})

      assert message =~ "expected integer"

      assert {:error, %InvalidInputError{details: details}} =
               Compiler.run(flow, %{value: 3}, %{})

      assert details.phase == :step_output
      assert details.node == :invalid
      assert details.action == InvalidOutput
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
