defmodule Jido.FlowDSLTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Flow
  alias JidoTest.FlowFixtures
  alias JidoTest.TestActions.{Add, Multiply}

  describe "use Jido.Flow" do
    test "exposes action-compatible metadata and validation callbacks" do
      module = unique_module("ValidatedMathFlow")
      schema = Zoi.object(%{value: Zoi.integer()})
      output_schema = Zoi.object(%{value: Zoi.integer()})

      create_module(
        module,
        quote do
          use Jido.Flow,
            name: "validated_math_flow",
            description: "Validated math flow",
            schema: unquote(Macro.escape(schema)),
            output_schema: unquote(Macro.escape(output_schema))

          flow do
            step(:add_one, unquote(Add), %{value: input(:value), amount: value(1)}, bind: :added)
            return(var(:added, :value))
          end
        end
      )

      assert module.name() == "validated_math_flow"
      assert module.description() == "Validated math flow"
      assert module.schema() == schema
      assert module.output_schema() == output_schema

      assert {:ok, %{value: 3, extra: "kept"}} =
               module.validate_params(%{value: 3, extra: "kept"})

      assert {:ok, %{value: 4}} = module.validate_output(%{value: 4})
    end

    test "flow, to_map, and compile are generated from the shared lowerer" do
      module = create_math_flow_module("MathFlow")

      assert flow = module.flow()
      assert flow.__struct__ == Flow
      assert module.to_map() == FlowFixtures.math_canonical_map()
      assert module.compile() == Flow.compile(flow)
    end

    test "variable bindings do not leak into the semantic canonical map" do
      module = create_math_flow_module("BindingMathFlow")

      canonical = module.to_map()
      refute canonical |> inspect() |> String.contains?("added")
      refute canonical |> inspect() |> String.contains?("doubled")
      assert canonical == FlowFixtures.math_canonical_map()
    end

    test "missing return fails at compile time" do
      module = unique_module("MissingReturnFlow")

      assert_raise CompileError, ~r/return ref is required/, fn ->
        create_module(
          module,
          quote do
            use Jido.Flow, name: "missing_return_flow"

            flow do
              step(:add_one, unquote(Add), %{value: input(:value)})
            end
          end
        )
      end
    end

    test "unsupported expressions inside flow fail at compile time" do
      module = unique_module("UnsupportedExpressionFlow")

      assert_raise CompileError, ~r/unsupported flow DSL expression/, fn ->
        create_module(
          module,
          quote do
            use Jido.Flow, name: "unsupported_expression_flow"

            flow do
              step(:add_one, unquote(Add), %{value: System.system_time()})
              return(result(:add_one, :value))
            end
          end
        )
      end
    end

    test "generated run delegates through Jido.Exec" do
      module = create_math_flow_module("DelegatingMathFlow")

      assert module.run(%{value: 3}, %{trace_id: "trace"}) ==
               Jido.Exec.run(module.flow(), %{value: 3}, %{trace_id: "trace"})
    end
  end

  defp create_math_flow_module(prefix) do
    module = unique_module(prefix)

    create_module(
      module,
      quote do
        use Jido.Flow,
          name: "math_flow",
          description: "Adds one and doubles the result"

        flow do
          step(:add_one, unquote(Add), %{value: input(:value), amount: value(1)}, bind: :added)

          step(:double, unquote(Multiply), %{value: var(:added, :value), amount: value(2)},
            bind: :doubled
          )

          return(var(:doubled, :value))
        end
      end
    )

    module
  end
end
