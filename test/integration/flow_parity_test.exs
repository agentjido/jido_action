defmodule Jido.Integration.FlowParityTest do
  use JidoTest.ActionCase, async: true
  use ExUnitProperties

  alias Jido.Flow.Builder
  alias Jido.Flow.Syntax
  alias Jido.Flow.Syntax.Lowerer
  alias JidoTest.FlowFixtures
  alias JidoTest.TestActions.{Add, EchoParamsAction, Multiply}

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

  test "macro, parser, builder, and direct syntax binding flows produce equal canonical maps" do
    module = unique_module("ParserParityBindingFlow")

    create_module(
      module,
      quote do
        use Jido.Flow,
          name: "binding_flow",
          description: "Adds one and doubles the whole result"

        flow do
          added = step(:add_one, unquote(Add), with: %{value: input(:value), amount: value(1)})
          doubled = step(:double, unquote(Multiply), with: added)
          return(doubled)
        end
      end
    )

    assert {:ok, direct_flow} = Lowerer.lower(FlowFixtures.binding_syntax())
    assert {:ok, builder_flow} = Builder.build(FlowFixtures.binding_builder())

    assert {:ok, parser_flow} =
             Jido.Flow.parse(FlowFixtures.binding_source(),
               name: "binding_flow",
               description: "Adds one and doubles the whole result"
             )

    assert module.to_map() == FlowFixtures.binding_canonical_map()
    assert module.to_map() == Jido.Flow.to_map(direct_flow)
    assert module.to_map() == Jido.Flow.to_map(builder_flow)
    assert module.to_map() == Jido.Flow.to_map(parser_flow)
  end

  test "macro, parser, builder, and direct syntax projection flows produce equal canonical maps" do
    module = create_projection_flow_module("ParserParityProjectionFlow")

    assert {:ok, direct_flow} = Lowerer.lower(FlowFixtures.projection_syntax())
    assert {:ok, builder_flow} = Builder.build(FlowFixtures.projection_builder())

    assert {:ok, parser_flow} =
             Jido.Flow.parse(FlowFixtures.projection_source(),
               name: "projection_flow",
               description: "Projects selected fields into an audit payload"
             )

    assert module.to_map() == FlowFixtures.projection_canonical_map()
    assert module.to_map() == Jido.Flow.to_map(direct_flow)
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

  test "binding parser canonical maps remain equal across formatting differences" do
    formatted_source = """
    flow do
      added =
        step :add_one,
          JidoTest.TestActions.Add,
          with: %{
            amount: value(1),
            value: input(:value)
          }

      doubled = step :double, JidoTest.TestActions.Multiply, with: added

      return doubled
    end
    """

    opts = [name: "binding_flow", description: "Adds one and doubles the whole result"]

    assert {:ok, parser_flow} = Jido.Flow.parse(FlowFixtures.binding_source(), opts)
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

  test "executing equivalent binding flows returns the same whole-result output" do
    module = unique_module("ExecutionParityBindingFlow")

    create_module(
      module,
      quote do
        use Jido.Flow,
          name: "binding_flow",
          description: "Adds one and doubles the whole result"

        flow do
          added = step(:add_one, unquote(Add), with: %{value: input(:value), amount: value(1)})
          doubled = step(:double, unquote(Multiply), with: added)
          return(doubled)
        end
      end
    )

    assert {:ok, builder_flow} = Builder.build(FlowFixtures.binding_builder())

    assert {:ok, parser_flow} =
             Jido.Flow.parse(FlowFixtures.binding_source(),
               name: "binding_flow",
               description: "Adds one and doubles the whole result"
             )

    assert {:ok, %{value: 8}} = Jido.Exec.run(builder_flow, %{value: 3}, %{})

    assert Jido.Exec.run(module, %{value: 3}, %{}) ==
             Jido.Exec.run(builder_flow, %{value: 3}, %{})

    assert Jido.Exec.run(parser_flow, %{value: 3}, %{}) ==
             Jido.Exec.run(builder_flow, %{value: 3}, %{})
  end

  test "executing equivalent projection flows extracts nested values and returns the selection" do
    module = create_projection_flow_module("ExecutionParityProjectionFlow")

    input = %{quote_id: "quote-1", items: [%{id: "item-1", price: 42}], tag: "priority"}

    assert {:ok, builder_flow} = Builder.build(FlowFixtures.projection_builder())

    assert {:ok, parser_flow} =
             Jido.Flow.parse(FlowFixtures.projection_source(),
               name: "projection_flow",
               description: "Projects selected fields into an audit payload"
             )

    assert {:ok, 42} = Jido.Exec.run(builder_flow, input, %{})

    assert Jido.Exec.run(module, input, %{}) ==
             Jido.Exec.run(builder_flow, input, %{})

    assert Jido.Exec.run(parser_flow, input, %{}) ==
             Jido.Exec.run(builder_flow, input, %{})
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

  defp create_projection_flow_module(prefix) do
    module = unique_module(prefix)

    create_module(
      module,
      quote do
        use Jido.Flow,
          name: "projection_flow",
          description: "Projects selected fields into an audit payload"

        flow do
          loaded =
            step(:load_quote, unquote(EchoParamsAction),
              with:
                shape(%{
                  quote: %{
                    id: input(:quote_id),
                    pricing: %{total: input([:items, 0, :price])}
                  },
                  tags: [input(:tag)]
                })
            )

          audit =
            step(:audit_quote, unquote(EchoParamsAction),
              with:
                shape(%{
                  quote_id: select(loaded, [:quote, :id]),
                  total: select(select(loaded, [:quote, :pricing]), :total),
                  first_item_id: select(input(:items), [0, :id]),
                  tag: select(loaded, [:tags, 0])
                })
            )

          return(select(audit, :total))
        end
      end
    )

    module
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
