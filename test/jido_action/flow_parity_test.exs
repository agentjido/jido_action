defmodule Jido.FlowParityTest do
  use JidoTest.ActionCase, async: true
  use ExUnitProperties

  alias Jido.Flow.Builder
  alias Jido.Flow.Syntax
  alias Jido.Flow.Syntax.Lowerer
  alias JidoTest.FlowFixtures
  alias JidoTest.TestActions.{Add, Multiply}

  test "macro and builder math flows produce equal canonical maps" do
    module = unique_module("MacroParityMathFlow")

    create_module(
      module,
      quote do
        use Jido.Flow,
          name: "math_flow",
          description: "Adds one and doubles the result"

        flow do
          step(:add_one, unquote(Add), %{value: input(:value), amount: value(1)})

          step(:double, unquote(Multiply), %{
            value: result(:add_one, :value),
            amount: value(2)
          })

          return(result(:double, :value))
        end
      end
    )

    assert {:ok, builder_flow} = Builder.build(FlowFixtures.math_builder())
    assert module.to_map() == Jido.Flow.to_map(builder_flow)
  end

  test "macro, builder, and parser math flows produce equal canonical maps" do
    module = unique_module("ParserParityMathFlow")

    create_module(
      module,
      quote do
        use Jido.Flow,
          name: "math_flow",
          description: "Adds one and doubles the result"

        flow do
          step(:add_one, unquote(Add), %{value: input(:value), amount: value(1)})

          step(:double, unquote(Multiply), %{
            value: result(:add_one, :value),
            amount: value(2)
          })

          return(result(:double, :value))
        end
      end
    )

    assert {:ok, builder_flow} = Builder.build(FlowFixtures.math_builder())

    assert {:ok, parser_flow} =
             Jido.Flow.parse(FlowFixtures.math_source(),
               name: "math_flow",
               description: "Adds one and doubles the result"
             )

    assert module.to_map() == Jido.Flow.to_map(builder_flow)
    assert module.to_map() == Jido.Flow.to_map(parser_flow)
  end

  test "parser canonical maps remain equal across formatting differences" do
    formatted_source = """
    flow do
      step :add_one, JidoTest.TestActions.Add, %{
        amount: value(1),
        value: input(:value)
      }

      step :double, JidoTest.TestActions.Multiply,
        %{amount: value(2), value: result(:add_one, :value)}

      return result(:double, :value)
    end
    """

    opts = [name: "math_flow", description: "Adds one and doubles the result"]

    assert {:ok, parser_flow} = Jido.Flow.parse(FlowFixtures.math_source(), opts)
    assert {:ok, formatted_flow} = Jido.Flow.parse(formatted_source, opts)
    assert Jido.Flow.to_map(parser_flow) == Jido.Flow.to_map(formatted_flow)
  end

  test "unsupported operation fixtures fail across macro, parser, and builder surfaces" do
    builder_syntax =
      Syntax.new(name: "bad")
      |> Syntax.add(Syntax.operation(:parallel, branches: []))

    assert {:error, builder_error} = Lowerer.lower(builder_syntax)
    assert Jido.Action.Error.to_map(builder_error).type == :validation_error

    parser_source = """
    flow do
      parallel :bad
    end
    """

    assert {:error, parser_error} = Jido.Flow.parse(parser_source, name: "bad")
    assert Jido.Action.Error.to_map(parser_error).type == :validation_error

    module = unique_module("UnsupportedParityFlow")

    assert_raise CompileError, ~r/unsupported flow DSL operation/, fn ->
      create_module(
        module,
        quote do
          use Jido.Flow, name: "bad"

          flow do
            parallel(:bad)
          end
        end
      )
    end
  end

  test "executing equivalent builder, macro, and parser flows returns the same result" do
    module = unique_module("ExecutionParityMathFlow")

    create_module(
      module,
      quote do
        use Jido.Flow,
          name: "math_flow",
          description: "Adds one and doubles the result"

        flow do
          step(:add_one, unquote(Add), %{value: input(:value), amount: value(1)})

          step(:double, unquote(Multiply), %{
            value: result(:add_one, :value),
            amount: value(2)
          })

          return(result(:double, :value))
        end
      end
    )

    assert {:ok, builder_flow} = Builder.build(FlowFixtures.math_builder())

    assert {:ok, parser_flow} =
             Jido.Flow.parse(FlowFixtures.math_source(),
               name: "math_flow",
               description: "Adds one and doubles the result"
             )

    assert {:ok, 8} = Jido.Exec.run(builder_flow, %{value: 3}, %{})

    assert Jido.Exec.run(module, %{value: 3}, %{}) ==
             Jido.Exec.run(builder_flow, %{value: 3}, %{})

    assert Jido.Exec.run(parser_flow, %{value: 3}, %{}) ==
             Jido.Exec.run(builder_flow, %{value: 3}, %{})
  end

  property "builder and syntax-lowered maps agree for simple Add chains" do
    check all(
            amounts <- list_of(integer(1..5), min_length: 1, max_length: 5),
            input <- integer(-100..100)
          ) do
      syntax = chain_syntax(amounts)
      builder = chain_builder(amounts)

      assert {:ok, syntax_flow} = Lowerer.lower(syntax)
      assert {:ok, builder_flow} = Builder.build(builder)
      assert Jido.Flow.to_map(builder_flow) == Jido.Flow.to_map(syntax_flow)
      expected = input + Enum.sum(amounts)
      assert {:ok, ^expected} = Jido.Exec.run(builder_flow, %{value: input}, %{})
    end
  end

  test "canonical maps omit syntax-only alias names" do
    assert {:ok, flow} = Builder.build(FlowFixtures.math_builder())
    canonical = Jido.Flow.to_map(flow)

    refute canonical |> inspect() |> String.contains?("added")
    refute canonical |> inspect() |> String.contains?("doubled")
  end

  defp chain_syntax(amounts) do
    Syntax.new(name: "chain")
    |> then(fn syntax ->
      amounts
      |> Enum.with_index(1)
      |> Enum.reduce(syntax, fn {amount, index}, acc ->
        input =
          if index == 1 do
            Syntax.input(:value)
          else
            Syntax.result(:"add_#{index - 1}", :value)
          end

        acc
        |> Syntax.step(:"add_#{index}", Add, %{value: input, amount: Syntax.value(amount)})
      end)
    end)
    |> Syntax.return(Syntax.result(:"add_#{length(amounts)}", :value))
  end

  defp chain_builder(amounts) do
    Builder.new(name: "chain")
    |> then(fn builder ->
      amounts
      |> Enum.with_index(1)
      |> Enum.reduce(builder, fn {amount, index}, acc ->
        input =
          if index == 1 do
            Builder.input(:value)
          else
            Builder.result(:"add_#{index - 1}", :value)
          end

        acc
        |> Builder.step(:"add_#{index}", Add, %{value: input, amount: Builder.value(amount)})
      end)
    end)
    |> Builder.return(Builder.result(:"add_#{length(amounts)}", :value))
  end
end
