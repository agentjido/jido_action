defmodule Jido.FlowBuilderTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Action.Error.InvalidInputError
  alias Jido.Flow
  alias Jido.Flow.Builder
  alias Jido.Flow.Syntax
  alias Jido.Flow.Syntax.Lowerer
  alias JidoTest.FlowFixtures
  alias JidoTest.TestActions.{Add, Multiply}

  describe "syntax lowerer" do
    test "lowers the first milestone operations to the expected canonical map" do
      assert {:ok, flow} = Lowerer.lower(FlowFixtures.math_syntax())
      assert Flow.to_map(flow) == FlowFixtures.math_canonical_map()
    end

    test "rejects unsupported syntax operations with the operation kind" do
      syntax =
        Syntax.new(name: "bad")
        |> Syntax.add(Syntax.operation(:parallel, branches: []))

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Lowerer.lower(syntax)

      assert message =~ "unsupported flow syntax operation"
      assert details.kind == :parallel
    end

    test "rejects result references before they are bound" do
      syntax =
        Syntax.new(name: "bad")
        |> Syntax.step(:double, Multiply, %{
          value: Syntax.result(:add_one, :value),
          amount: Syntax.value(2)
        })
        |> Syntax.step(:add_one, Add, %{value: Syntax.input(:value)})
        |> Syntax.return(Syntax.result(:double, :value))

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Lowerer.lower(syntax)

      assert message =~ "result reference before it is bound"
      assert details.step == :double
      assert details.dependency == :add_one
    end

    test "missing return errors identify the return declaration" do
      syntax =
        Syntax.new(name: "bad")
        |> Syntax.step(:add_one, Add, %{value: Syntax.input(:value)})

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Lowerer.lower(syntax)

      assert message =~ "return ref is required"
      assert details.operation == :return
    end

    test "accepts structured maps whose leaves are supported refs or literals" do
      syntax =
        Syntax.new(name: "structured")
        |> Syntax.step(:add_one, Add, %{
          nested: %{
            input: Syntax.input([:payload, :value]),
            literal: Syntax.value(%{amount: 1})
          }
        })
        |> Syntax.return(Syntax.result(:add_one))

      assert {:ok, flow} = Lowerer.lower(syntax)
      assert [node] = Flow.to_map(flow).nodes

      assert node.input.nested == %{
               input: %{type: :input, path: [:payload, :value]},
               literal: %{type: :value, value: %{amount: 1}}
             }
    end
  end

  describe "builder" do
    test "does not expose variable binding aliases in the first foundation" do
      refute function_exported?(Syntax, :var, 1)
      refute function_exported?(Syntax, :var, 2)
      refute function_exported?(Syntax, :bind, 3)
      refute function_exported?(Builder, :var, 1)
      refute function_exported?(Builder, :var, 2)
      refute function_exported?(Builder, :bind, 3)
    end

    test "builder-created syntax and direct syntax emit equal canonical maps" do
      assert {:ok, direct_flow} = Lowerer.lower(FlowFixtures.math_syntax())
      assert {:ok, builder_flow} = Builder.build(FlowFixtures.math_builder())

      assert Flow.to_map(builder_flow) == Flow.to_map(direct_flow)
      assert Flow.to_map(builder_flow) == FlowFixtures.math_canonical_map()
    end

    test "builder syntax cannot shortcut the canonical map" do
      assert builder = FlowFixtures.math_builder()
      assert %Syntax{} = Builder.syntax(builder)
      assert {:ok, flow} = Builder.build(builder)

      canonical = Flow.to_map(flow)
      refute Map.has_key?(canonical, :bindings)
      refute canonical |> inspect() |> String.contains?("added")
      refute canonical |> inspect() |> String.contains?("builder")
    end
  end
end
