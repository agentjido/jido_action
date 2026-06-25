defmodule Jido.Flow.Syntax.LowererTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Action.Error.InvalidInputError
  alias Jido.Flow
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

    test "rejects malformed operation values" do
      syntax =
        Syntax.new(name: "bad")
        |> Map.put(:operations, [:not_an_operation])

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Lowerer.lower(syntax)

      assert message =~ "unsupported flow syntax operation"
      assert details.operation == :not_an_operation
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

    test "rejects returns that do not resolve to result refs" do
      syntax =
        Syntax.new(name: "bad")
        |> Syntax.step(:add_one, Add, %{value: Syntax.input(:value)})
        |> Syntax.return(Syntax.value(:not_a_result))

      assert {:error, %InvalidInputError{message: message}} = Lowerer.lower(syntax)
      assert message =~ "return must resolve to a result ref"
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

    test "lowers lists while preserving order and nested refs" do
      syntax =
        Syntax.new(name: "list_input")
        |> Syntax.step(:add_one, Add, %{
          values: [Syntax.input(:value), Syntax.value(2)]
        })
        |> Syntax.return(Syntax.result(:add_one))

      assert {:ok, flow} = Lowerer.lower(syntax)
      assert [node] = Flow.to_map(flow).nodes

      assert node.input.values == [
               %{type: :input, path: [:value]},
               %{type: :value, value: 2}
             ]
    end
  end
end
