defmodule Jido.Integration.FlowParityTest do
  use JidoTest.ActionCase, async: true
  use ExUnitProperties

  alias Jido.Action.Error
  alias Jido.Flow.Builder
  alias Jido.Flow.Syntax
  alias Jido.Flow.Syntax.Lowerer
  alias JidoTest.FlowFixtures
  alias JidoTest.TestActions.{Add, EchoParamsAction, Multiply}

  describe "authoring parity" do
    test "supported surfaces produce equal canonical maps" do
      for scenario <- flow_cases() do
        assert_canonical_parity(scenario)
      end
    end

    test "branch grouping lowers away except for provenance" do
      assert {:ok, grouped_flow} = Lowerer.lower(FlowFixtures.branch_group_syntax())
      assert {:ok, flattened_flow} = Lowerer.lower(FlowFixtures.branch_group_flattened_syntax())

      semantic_map = Jido.Flow.to_map(grouped_flow)

      assert semantic_map == FlowFixtures.branch_group_canonical_map()
      assert semantic_map == Jido.Flow.to_map(flattened_flow)

      refute inspect(semantic_map) =~ "alpha"
      refute inspect(semantic_map) =~ "beta"

      assert [
               _load_cart,
               %{provenance: %{branch: :alpha}},
               %{provenance: %{branch: :alpha}},
               %{provenance: %{branch: :beta}},
               _post_group_independent,
               _finalize
             ] = Jido.Flow.to_map(grouped_flow, provenance: true).nodes
    end

    test "context fixture keeps runtime values out of canonical maps" do
      flow = FlowFixtures.context_builder() |> build_flow!()
      canonical = Jido.Flow.to_map(flow)

      assert canonical == FlowFixtures.context_canonical_map()
      assert inspect(canonical) =~ "context"
      refute inspect(canonical) =~ "context-trace"

      input = %{user_id: "user-1", trace_id: "input-trace"}

      assert {:ok, first_result} =
               Jido.Exec.run(flow, input, %{trace_id: "context-trace-1", tenant: %{id: "t-1"}})

      assert {:ok, second_result} =
               Jido.Exec.run(flow, input, %{trace_id: "context-trace-2", tenant: %{id: "t-2"}})

      assert first_result == %{
               user_id: "user-1",
               input_trace_id: "input-trace",
               context_trace_id: "context-trace-1",
               tenant_id: "t-1"
             }

      assert second_result == %{
               user_id: "user-1",
               input_trace_id: "input-trace",
               context_trace_id: "context-trace-2",
               tenant_id: "t-2"
             }

      assert Jido.Flow.to_map(flow) == canonical
    end

    test "parser canonical maps remain stable across formatting variations" do
      for scenario <- parser_format_cases() do
        assert {:ok, parser_flow} = Jido.Flow.parse(scenario.source, scenario.opts)
        assert {:ok, formatted_flow} = Jido.Flow.parse(scenario.formatted_source, scenario.opts)

        assert Jido.Flow.to_map(formatted_flow) == Jido.Flow.to_map(parser_flow),
               "#{scenario.label} parser formatting changed canonical map"
      end
    end

    test "unsupported operations fail consistently across surfaces" do
      builder_syntax =
        Syntax.new(name: "bad")
        |> Syntax.add(Syntax.operation(:choose, branches: []))

      assert {:error, builder_error} = Lowerer.lower(builder_syntax)
      assert Error.to_map(builder_error).type == :validation_error

      parser_source = """
      flow do
        choose :bad
      end
      """

      assert {:error, parser_error} = Jido.Flow.parse(parser_source, name: "bad")
      assert Error.to_map(parser_error).type == :validation_error

      module = unique_module("UnsupportedParityFlow")

      assert_raise CompileError, ~r/unsupported flow DSL operation/, fn ->
        create_module(
          module,
          quote do
            use Jido.Flow, name: "bad"

            flow do
              choose(:bad)
            end
          end
        )
      end
    end
  end

  describe "execution parity" do
    test "supported surfaces return the same values" do
      for scenario <- flow_cases() do
        assert_execution_parity(scenario)
      end
    end
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

  defp assert_canonical_parity(scenario) do
    expected = scenario.canonical.()

    for {surface, actual} <- canonical_surface_maps(scenario) do
      assert actual == expected, "#{scenario.label} #{surface} canonical map diverged"
    end
  end

  defp assert_execution_parity(scenario) do
    expected = {:ok, scenario.expected}
    context = Map.get(scenario, :context, %{})

    for {surface, flow} <- executable_flows(scenario) do
      assert Jido.Exec.run(flow, scenario.input, context) == expected,
             "#{scenario.label} #{surface} execution diverged"
    end
  end

  defp canonical_surface_maps(scenario) do
    module = scenario.module.("CanonicalParity#{scenario.module_suffix}")

    [
      macro: module.to_map(),
      direct_syntax: scenario.syntax.() |> lower_flow!() |> Jido.Flow.to_map(),
      builder: scenario.builder.() |> build_flow!() |> Jido.Flow.to_map(),
      parser: scenario.source.() |> parse_flow!(scenario.opts) |> Jido.Flow.to_map()
    ] ++ equivalent_syntax_maps(scenario)
  end

  defp equivalent_syntax_maps(scenario) do
    scenario
    |> Map.get(:equivalent_syntaxes, [])
    |> Enum.map(fn {surface, syntax_fun} ->
      {surface, syntax_fun.() |> lower_flow!() |> Jido.Flow.to_map()}
    end)
  end

  defp executable_flows(scenario) do
    module = scenario.module.("ExecutionParity#{scenario.module_suffix}")

    [
      macro: module.flow(),
      direct_syntax: scenario.syntax.() |> lower_flow!(),
      builder: scenario.builder.() |> build_flow!(),
      parser: scenario.source.() |> parse_flow!(scenario.opts)
    ]
  end

  defp lower_flow!(syntax) do
    assert {:ok, flow} = Lowerer.lower(syntax)
    flow
  end

  defp build_flow!(builder) do
    assert {:ok, flow} = Builder.build(builder)
    flow
  end

  defp parse_flow!(source, opts) do
    assert {:ok, flow} = Jido.Flow.parse(source, opts)
    flow
  end

  defp flow_cases do
    [
      %{
        label: "math",
        module_suffix: "MathFlow",
        module: &create_math_flow_module/1,
        opts: [name: "math_flow", description: "Adds one and doubles the result"],
        syntax: &FlowFixtures.math_syntax/0,
        builder: &FlowFixtures.math_builder/0,
        source: &FlowFixtures.math_source/0,
        canonical: &FlowFixtures.math_canonical_map/0,
        input: %{value: 3},
        expected: 8
      },
      %{
        label: "binding",
        module_suffix: "BindingFlow",
        module: &create_binding_flow_module/1,
        opts: [name: "binding_flow", description: "Adds one and doubles the whole result"],
        syntax: &FlowFixtures.binding_syntax/0,
        builder: &FlowFixtures.binding_builder/0,
        source: &FlowFixtures.binding_source/0,
        canonical: &FlowFixtures.binding_canonical_map/0,
        input: %{value: 3},
        expected: %{value: 8}
      },
      %{
        label: "projection",
        module_suffix: "ProjectionFlow",
        module: &create_projection_flow_module/1,
        opts: [
          name: "projection_flow",
          description: "Projects selected fields into an audit payload"
        ],
        syntax: &FlowFixtures.projection_syntax/0,
        builder: &FlowFixtures.projection_builder/0,
        source: &FlowFixtures.projection_source/0,
        canonical: &FlowFixtures.projection_canonical_map/0,
        input: %{quote_id: "quote-1", items: [%{id: "item-1", price: 42}], tag: "priority"},
        expected: 42
      },
      %{
        label: "context",
        module_suffix: "ContextFlow",
        module: &create_context_flow_module/1,
        opts: [
          name: "context_flow",
          description: "Shapes runtime context into an audit payload"
        ],
        syntax: &FlowFixtures.context_syntax/0,
        builder: &FlowFixtures.context_builder/0,
        source: &FlowFixtures.context_source/0,
        canonical: &FlowFixtures.context_canonical_map/0,
        input: %{user_id: "user-1", trace_id: "input-trace"},
        context: %{trace_id: "context-trace", tenant: %{id: "tenant-1"}},
        expected: %{
          user_id: "user-1",
          input_trace_id: "input-trace",
          context_trace_id: "context-trace",
          tenant_id: "tenant-1"
        }
      },
      %{
        label: "explicit-edge",
        module_suffix: "ExplicitEdgeFlow",
        module: &create_explicit_edge_flow_module/1,
        opts: [
          name: "explicit_edge_flow",
          description: "Orders audit after loading without data dependency"
        ],
        syntax: &FlowFixtures.explicit_edge_syntax/0,
        builder: &FlowFixtures.explicit_edge_builder/0,
        source: &FlowFixtures.explicit_edge_source/0,
        canonical: &FlowFixtures.explicit_edge_canonical_map/0,
        input: %{quote_id: "quote-1"},
        expected: %{event: "quoted"}
      },
      %{
        label: "branch-group",
        module_suffix: "BranchGroupFlow",
        module: &create_branch_group_flow_module/1,
        opts: [
          name: "branch_group_flow",
          description: "Groups static branches without changing runtime semantics"
        ],
        syntax: &FlowFixtures.branch_group_syntax/0,
        equivalent_syntaxes: [
          flattened_syntax: &FlowFixtures.branch_group_flattened_syntax/0
        ],
        builder: &FlowFixtures.branch_group_builder/0,
        source: &FlowFixtures.branch_group_source/0,
        canonical: &FlowFixtures.branch_group_canonical_map/0,
        input: %{cart_id: "cart-1", items: [%{sku: "sku-1"}], total: 42},
        expected: %{
          priced: %{cart_id: "cart-1", total: 42},
          reserved: %{cart_id: "cart-1", items: [%{sku: "sku-1"}]}
        }
      }
    ]
  end

  defp parser_format_cases do
    [
      %{
        label: "math",
        source: FlowFixtures.math_source(),
        opts: [name: "math_flow", description: "Adds one and doubles the result"],
        formatted_source: """
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
      },
      %{
        label: "binding",
        source: FlowFixtures.binding_source(),
        opts: [name: "binding_flow", description: "Adds one and doubles the whole result"],
        formatted_source: """
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
      }
    ]
  end

  defp create_math_flow_module(prefix) do
    create_flow_module(
      prefix,
      "math_flow",
      "Adds one and doubles the result",
      quote do
        step(:add_one, unquote(Add), %{value: input(:value), amount: value(1)})

        step(:double, unquote(Multiply), %{
          value: result(:add_one, :value),
          amount: value(2)
        })

        return(result(:double, :value))
      end
    )
  end

  defp create_binding_flow_module(prefix) do
    create_flow_module(
      prefix,
      "binding_flow",
      "Adds one and doubles the whole result",
      quote do
        added = step(:add_one, unquote(Add), with: %{value: input(:value), amount: value(1)})
        doubled = step(:double, unquote(Multiply), with: added)
        return(doubled)
      end
    )
  end

  defp create_projection_flow_module(prefix) do
    create_flow_module(
      prefix,
      "projection_flow",
      "Projects selected fields into an audit payload",
      quote do
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
    )
  end

  defp create_explicit_edge_flow_module(prefix) do
    create_flow_module(
      prefix,
      "explicit_edge_flow",
      "Orders audit after loading without data dependency",
      quote do
        loaded =
          step(:load_quote, unquote(EchoParamsAction), with: shape(%{id: input(:quote_id)}))

        step(:independent, unquote(EchoParamsAction), with: shape(%{event: "side"}))

        audit =
          step(:audit_quote, unquote(EchoParamsAction),
            with: shape(%{event: "quoted"}),
            after: [:load_quote, loaded]
          )

        return(audit)
      end
    )
  end

  defp create_context_flow_module(prefix) do
    create_flow_module(
      prefix,
      "context_flow",
      "Shapes runtime context into an audit payload",
      quote do
        audit =
          step(:audit_request, unquote(EchoParamsAction),
            with:
              shape(%{
                user_id: input(:user_id),
                input_trace_id: input(:trace_id),
                context_trace_id: context(:trace_id),
                tenant_id: select(context(:tenant), :id)
              })
          )

        return(audit)
      end
    )
  end

  defp create_branch_group_flow_module(prefix) do
    create_flow_module(
      prefix,
      "branch_group_flow",
      "Groups static branches without changing runtime semantics",
      quote do
        cart =
          step(:load_cart, unquote(EchoParamsAction),
            with:
              shape(%{
                cart_id: input(:cart_id),
                items: input(:items)
              })
          )

        parallel do
          branch :alpha do
            priced =
              step(:price_cart, unquote(EchoParamsAction),
                with:
                  shape(%{
                    cart_id: select(cart, :cart_id),
                    total: input(:total)
                  })
              )

            step(:audit_price, unquote(EchoParamsAction),
              with: shape(%{event: "priced"}),
              after: priced
            )
          end

          branch :beta do
            reserved =
              step(:reserve_inventory, unquote(EchoParamsAction),
                with:
                  shape(%{
                    cart_id: select(cart, :cart_id),
                    items: select(cart, :items)
                  })
              )
          end
        end

        step(:post_group_independent, unquote(EchoParamsAction), with: shape(%{event: "side"}))

        final =
          step(:finalize, unquote(EchoParamsAction),
            with:
              shape(%{
                priced: priced,
                reserved: reserved
              })
          )

        return(final)
      end
    )
  end

  defp create_flow_module(prefix, name, description, quoted_flow) do
    module = unique_module(prefix)

    create_module(
      module,
      quote do
        use Jido.Flow,
          name: unquote(name),
          description: unquote(description)

        flow do
          unquote(quoted_flow)
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
