defmodule Jido.Flow.DSLTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Flow
  alias JidoTest.FlowFixtures
  alias JidoTest.TestActions.{Add, EchoParamsAction, Multiply}

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
            step(:add_one, unquote(Add), %{value: input(:value), amount: value(1)})
            return(result(:add_one, :value))
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

    test "supports binding assignments, with input, and return by binding" do
      module = unique_module("BindingFlow")

      create_module(
        module,
        quote do
          use Jido.Flow, name: "binding_flow"

          flow do
            added = step(:add_one, unquote(Add), with: %{value: input(:value), amount: 1})
            doubled = step(:double, unquote(Multiply), with: added)
            return(doubled)
          end
        end
      )

      assert [add_one, double] = module.to_map().nodes
      assert add_one.input.value == %{type: :input, path: [:value]}
      assert add_one.input.amount == %{type: :value, value: 1}
      assert double.input == %{type: :result, node: :add_one, path: []}
      assert module.to_map().return == %{type: :result, node: :double, path: []}
    end

    test "rejects bind step options at compile time" do
      module = unique_module("BindOptionFlow")

      assert_raise CompileError, ~r/unsupported flow DSL step options/, fn ->
        create_module(
          module,
          quote do
            use Jido.Flow, name: "bind_option_flow"

            flow do
              step(:add_one, unquote(Add), %{value: input(:value)}, bind: :added)
              return(result(:add_one, :value))
            end
          end
        )
      end
    end

    test "rejects invalid binding assignments at compile time" do
      cases = [
        {:right_side, quote(do: added = input(:value))},
        {:pattern, quote(do: %{added: added} = step(:add_one, unquote(Add), with: %{}))},
        {:nested, quote(do: added = doubled = step(:add_one, unquote(Add), with: %{}))}
      ]

      for {case_name, statement} <- cases do
        module = unique_module("InvalidBinding#{case_name}")

        assert_raise CompileError, ~r/unsupported flow DSL binding assignment/, fn ->
          create_module(
            module,
            quote do
              use Jido.Flow, name: "invalid_binding_flow"

              flow do
                unquote(statement)
                return(result(:add_one))
              end
            end
          )
        end
      end
    end

    test "rejects unbound handles at compile time" do
      module = unique_module("UnboundHandleFlow")

      assert_raise CompileError, ~r/unknown binding handle/, fn ->
        create_module(
          module,
          quote do
            use Jido.Flow, name: "unbound_handle_flow"

            flow do
              step(:double, unquote(Multiply), with: missing)
              return(result(:double))
            end
          end
        )
      end
    end

    test "rejects wildcard binding assignments at compile time" do
      module = unique_module("WildcardBindingFlow")

      assert_raise CompileError, ~r/reserved binding alias: :_/, fn ->
        create_module(
          module,
          quote do
            use Jido.Flow, name: "wildcard_binding_flow"

            flow do
              _ = step(:add_one, unquote(Add), with: %{value: input(:value)})
              return(result(:add_one))
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

    test "supports projection-only select and shape expressions" do
      module = unique_module("ProjectionShapeFlow")

      create_module(
        module,
        quote do
          use Jido.Flow, name: "projection_shape_flow"

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
                    first_item_id: select(input(:items), [0, :id])
                  })
              )

            return(select(audit, :total))
          end
        end
      )

      assert [_load_quote, audit_quote] = module.to_map().nodes

      assert audit_quote.input == %{
               quote_id: %{type: :result, node: :load_quote, path: [:quote, :id]},
               total: %{
                 type: :result,
                 node: :load_quote,
                 path: [:quote, :pricing, :total]
               },
               first_item_id: %{type: :input, path: [:items, 0, :id]}
             }

      assert module.to_map().return == %{type: :result, node: :audit_quote, path: [:total]}
    end

    test "rejects unsupported projection and shape expressions at compile time" do
      cases = [
        {:computed_shape,
         quote(
           do: step(:bad, unquote(EchoParamsAction), with: shape(%{x: System.system_time()}))
         ), ~r/unsupported flow DSL expression/},
        {:computed_path,
         quote(
           do:
             step(:bad, unquote(EchoParamsAction),
               with: %{x: select(input(:payload), System.system_time())}
             )
         ), ~r/unsupported flow DSL expression/},
        {:dot_projection,
         quote(
           do: step(:bad, unquote(EchoParamsAction), with: shape(%{x: input(:payload).value}))
         ), ~r/unsupported flow DSL expression/},
        {:value_source,
         quote(do: step(:bad, unquote(EchoParamsAction), with: %{x: select(value(%{}), :id)})),
         ~r/select source must resolve to an input or result ref/}
      ]

      for {case_name, statements, expected} <- cases do
        module = unique_module("UnsupportedProjection#{case_name}")

        assert_raise CompileError, expected, fn ->
          create_module(
            module,
            quote do
              use Jido.Flow, name: "unsupported_projection_flow"

              flow do
                unquote(statements)
                return(result(:bad))
              end
            end
          )
        end
      end
    end

    test "parses direct literals, list paths, map paths, and result refs without paths" do
      module = unique_module("LiteralPathFlow")

      create_module(
        module,
        quote do
          use Jido.Flow, name: "literal_path_flow"

          flow do
            step(:add_one, unquote(Add), %{
              value: input([:payload, "value", 0]),
              amount: 1,
              config: value(%{path: [:payload, "value"]}),
              metadata_path: input(%{field: :value})
            })

            return(result(:add_one))
          end
        end
      )

      assert [node] = module.to_map().nodes
      assert node.input.value == %{type: :input, path: [:payload, "value", 0]}
      assert node.input.amount == %{type: :value, value: 1}
      assert node.input.config == %{type: :value, value: %{path: [:payload, "value"]}}
      assert node.input.metadata_path == %{type: :input, path: [%{field: :value}]}
      assert module.to_map().return == %{type: :result, node: :add_one, path: []}
    end

    test "rejects unsupported result node expressions" do
      module = unique_module("UnsupportedResultNodeFlow")

      assert_raise CompileError, ~r/unsupported flow DSL result node/, fn ->
        create_module(
          module,
          quote do
            use Jido.Flow, name: "unsupported_result_node_flow"

            flow do
              step(:add_one, unquote(Add), %{value: input(:value)})
              return(result(System.system_time()))
            end
          end
        )
      end
    end

    test "rejects unsupported literal expressions inside value calls" do
      module = unique_module("UnsupportedLiteralFlow")

      assert_raise CompileError, ~r/unsupported flow DSL expression/, fn ->
        create_module(
          module,
          quote do
            use Jido.Flow, name: "unsupported_literal_flow"

            flow do
              step(:add_one, unquote(Add), %{value: value(System.system_time())})
              return(result(:add_one))
            end
          end
        )
      end
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
          step(:add_one, unquote(Add), %{value: input(:value), amount: value(1)})

          step(:double, unquote(Multiply), %{
            value: result(:add_one, :value),
            amount: value(2)
          })

          return(result(:double, :value))
        end
      end
    )

    module
  end
end
