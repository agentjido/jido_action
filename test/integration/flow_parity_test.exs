defmodule Jido.Integration.FlowParityTest do
  use JidoTest.ActionCase, async: true
  use ExUnitProperties
  @moduletag capture_log: true

  alias Jido.Action.Error.ExecutionFailureError
  alias Jido.Flow.Builder
  alias Jido.Flow.{ContractBundle, Node, Ref}
  alias Jido.Flow.Syntax
  alias Jido.Flow.Syntax.Lowerer
  alias JidoTest.FlowFixtures
  alias JidoTest.TestActions.{Add, EchoParamsAction, ErrorAction, Multiply, RecorderAction}

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
               %{name: "load_cart"},
               %{name: "post_group_independent", provenance: %{}},
               %{name: "price_cart", provenance: %{branch: :alpha}},
               %{name: "reserve_inventory", provenance: %{branch: :beta}},
               %{name: "audit_price", provenance: %{branch: :alpha}},
               %{name: "finalize"}
             ] = Jido.Flow.to_map(grouped_flow, provenance: true).nodes

      stored_flow = stored_json_round_trip_flow!(grouped_flow, provenance: true)

      assert Jido.Flow.to_map(stored_flow) == semantic_map

      assert [
               %{name: "load_cart"},
               %{name: "post_group_independent", provenance: %{}},
               %{name: "price_cart", provenance: %{branch: :alpha}},
               %{name: "reserve_inventory", provenance: %{branch: :beta}},
               %{name: "audit_price", provenance: %{branch: :alpha}},
               %{name: "finalize"}
             ] = Jido.Flow.to_map(stored_flow, provenance: true).nodes
    end

    test "step annotations stay in provenance across authoring surfaces" do
      scenario = Enum.find(flow_cases(), &(&1.label == "annotated"))

      expected = %{
        label: "Add one",
        tags: ["math", "example"],
        note: "Visible only in provenance"
      }

      for {surface, flow} <- executable_flows(scenario) do
        assert Jido.Flow.to_map(flow) == FlowFixtures.annotated_canonical_map(),
               "#{surface} annotations changed semantic map"

        assert [%{provenance: provenance}] = Jido.Flow.to_map(flow, provenance: true).nodes

        assert Map.take(provenance, [:label, :tags, :note]) == expected,
               "#{surface} annotations changed provenance"
      end
    end

    test "stored source resolves registered actions to the trusted canonical map" do
      opts = [
        name: "annotated_flow",
        description: "Annotates a step without changing semantics"
      ]

      assert {:ok, trusted_flow} = Jido.Flow.parse(FlowFixtures.annotated_source(), opts)

      assert {:ok, stored_flow} =
               Jido.Flow.parse(
                 FlowFixtures.stored_annotated_source(),
                 Keyword.merge(opts,
                   profile: :stored,
                   actions: %{"add" => Add}
                 )
               )

      assert Jido.Flow.to_map(stored_flow) == FlowFixtures.annotated_canonical_map()
      assert Jido.Flow.to_map(stored_flow) == Jido.Flow.to_map(trusted_flow)
      assert {:ok, %{value: 4}} = Jido.Exec.run(stored_flow, %{value: 3}, %{})
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

    test "Choice semantic data agrees across the five authoring surfaces" do
      syntax_flow = choice_syntax() |> lower_flow!()
      builder_flow = choice_builder() |> build_flow!()
      module = create_choice_flow_module("ChoiceParity")

      assert {:ok, trusted_flow} = Jido.Flow.parse(choice_source(), name: "choice_parity")

      assert {:ok, stored_flow} =
               Jido.Flow.parse(choice_stored_source(),
                 name: "choice_parity",
                 profile: :stored,
                 actions: %{"add" => Add, "multiply" => Multiply}
               )

      expected = Jido.Flow.to_map(syntax_flow)

      for {surface, flow} <- [
            module_dsl: module.flow(),
            syntax_lowerer: syntax_flow,
            builder: builder_flow,
            trusted_source_parser: trusted_flow,
            stored_source_parser: stored_flow
          ] do
        assert Jido.Flow.to_map(flow) == expected, "#{surface} Choice map diverged"
        assert Jido.Flow.dependencies(flow) == Jido.Flow.dependencies(syntax_flow)
        assert {:ok, %{nodes: nodes}} = Jido.Flow.explain(flow)
        assert {:ok, %{nodes: expected_nodes}} = Jido.Flow.explain(syntax_flow)
        assert nodes == expected_nodes
        assert Jido.Flow.semantic_identity(flow) == Jido.Flow.semantic_identity(syntax_flow)

        assert {:ok, %{value: 4}} = Jido.Exec.run(flow, %{kind: :priority, value: 3}, %{}),
               "#{surface} Choice priority execution diverged"

        assert {:ok, %{value: 6}} = Jido.Exec.run(flow, %{kind: :standard, value: 3}, %{}),
               "#{surface} Choice non-priority execution diverged"
      end
    end

    test "Map and Reduce agree across the five authoring surfaces" do
      syntax_flow = map_reduce_syntax() |> lower_flow!()
      builder_flow = map_reduce_builder() |> build_flow!()
      module = create_map_reduce_flow_module("MapReduceParity")

      assert {:ok, trusted_flow} =
               Jido.Flow.parse(map_reduce_source(), name: "map_reduce_parity")

      assert {:ok, stored_flow} =
               Jido.Flow.parse(map_reduce_stored_source(),
                 name: "map_reduce_parity",
                 profile: :stored,
                 actions: %{"add" => Add, "multiply" => Multiply}
               )

      expected_map = Jido.Flow.to_map(syntax_flow)
      expected_dependencies = Jido.Flow.dependencies(syntax_flow)
      expected_explanation = Jido.Flow.explain(syntax_flow)
      expected_identity = Jido.Flow.semantic_identity(syntax_flow)
      expected_compile = Jido.Flow.compile(syntax_flow)

      for {surface, flow} <- [
            module_dsl: module.flow(),
            syntax_lowerer: syntax_flow,
            builder: builder_flow,
            trusted_source_parser: trusted_flow,
            stored_source_parser: stored_flow
          ] do
        assert Jido.Flow.to_map(flow) == expected_map, "#{surface} Map/Reduce map diverged"
        assert Jido.Flow.dependencies(flow) == expected_dependencies
        assert Jido.Flow.explain(flow) == expected_explanation
        assert Jido.Flow.semantic_identity(flow) == expected_identity
        assert Jido.Flow.compile(flow) == expected_compile

        for options <- [[], [async: true, max_concurrency: 2]] do
          assert {:ok, %{value: 24}} =
                   Jido.Exec.run(
                     flow,
                     %{items: [%{value: 1}, %{value: 2}, %{value: 3}]},
                     %{},
                     options
                   ),
                 "#{surface} Map/Reduce runtime diverged for #{inspect(options)}"
        end
      end
    end
  end

  describe "portable stored parity" do
    test "transport aliases preserve semantic inspection, compile, check, and execution" do
      semantic_map = choice_syntax() |> lower_flow!() |> Jido.Flow.to_map()
      assert {:ok, semantic_flow} = Jido.Flow.from_map(semantic_map)

      {first_stored, first_flow} =
        stored_json_artifact_and_flow!(semantic_flow, "parity/first")

      {second_stored, second_flow} =
        stored_json_artifact_and_flow!(semantic_flow, "parity/second")

      refute first_stored == second_stored
      refute first_stored["contracts"] == second_stored["contracts"]
      refute first_stored["nodes"] == second_stored["nodes"]

      expected_semantic_map = semantic_map
      expected_dependencies = Jido.Flow.dependencies(semantic_flow)
      expected_explanation = Jido.Flow.explain(semantic_flow)
      expected_identity = Jido.Flow.semantic_identity(semantic_flow)
      expected_compile = Jido.Flow.compile(semantic_flow)

      for flow <- [first_flow, second_flow] do
        assert Jido.Flow.to_map(flow) == expected_semantic_map
        assert Jido.Flow.dependencies(flow) == expected_dependencies
        assert Jido.Flow.explain(flow) == expected_explanation
        assert Jido.Flow.semantic_identity(flow) == expected_identity
        assert Jido.Flow.compile(flow) == expected_compile
      end

      for flow <- [semantic_flow, first_flow, second_flow] do
        assert :ok = Jido.Flow.check(flow)

        assert {:ok, %{value: 4}} =
                 Jido.Exec.run(flow, %{kind: :priority, value: 3}, %{})

        assert {:ok, %{value: 6}} =
                 Jido.Exec.run(flow, %{kind: :standard, value: 3}, %{})
      end
    end
  end

  describe "execution parity" do
    test "supported surfaces return the same values" do
      for scenario <- flow_cases() do
        assert_execution_parity(scenario)
      end
    end

    test "public execution returns branch errors while independent roots still run" do
      flow =
        Jido.Flow.new!(
          name: "public_branch_failure",
          nodes: [
            Node.new!(
              name: :bad,
              action: ErrorAction,
              input: %{error_type: Ref.value(:validation)}
            ),
            Node.new!(
              name: :recorder,
              action: RecorderAction,
              input: %{value: Ref.input(:value)}
            ),
            Node.new!(
              name: :dependent,
              action: RecorderAction,
              input: %{from_bad: Ref.result(:bad)}
            )
          ],
          return: Ref.result(:recorder)
        )

      assert {:error, %ExecutionFailureError{message: "Validation error", details: details}} =
               Jido.Exec.run(flow, %{value: 7}, %{test_pid: self()})

      assert details.phase == :step_execution
      assert details.node == "bad"
      assert details.action == ErrorAction
      assert_receive {RecorderAction, %{value: 7}}
      refute_receive {RecorderAction, %{from_bad: _}}
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
      expected = %{value: input + Enum.sum(amounts)}
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
    stored_flow = scenario.builder.() |> build_flow!() |> stored_json_round_trip_flow!()

    [
      macro: module.to_map(),
      direct_syntax: scenario.syntax.() |> lower_flow!() |> Jido.Flow.to_map(),
      builder: scenario.builder.() |> build_flow!() |> Jido.Flow.to_map(),
      parser: scenario.source.() |> parse_flow!(scenario.opts) |> Jido.Flow.to_map(),
      stored_json: Jido.Flow.to_map(stored_flow)
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

    stored_flow =
      scenario.builder.()
      |> build_flow!()
      |> stored_json_round_trip_flow!(provenance: true)

    [
      macro: module.flow(),
      direct_syntax: scenario.syntax.() |> lower_flow!(),
      builder: scenario.builder.() |> build_flow!(),
      parser: scenario.source.() |> parse_flow!(scenario.opts),
      stored_json: stored_flow
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

  defp stored_json_round_trip_flow!(flow, opts \\ []) do
    {_stored, loaded} = stored_json_artifact_and_flow!(flow, "integration/default", opts)
    loaded
  end

  defp stored_json_artifact_and_flow!(flow, namespace, opts \\ []) do
    registry = flow_action_registry(namespace)

    references = %{
      bundle: "#{namespace}/bundle/v1",
      input_schema: "#{namespace}/input/v1",
      output_schema: "#{namespace}/output/v1",
      action_registry: "#{namespace}/actions/v1"
    }

    bundle =
      ContractBundle.new!(
        id: references.bundle,
        schemas: %{
          references.input_schema => flow.schema,
          references.output_schema => flow.output_schema
        },
        action_registries: %{references.action_registry => registry}
      )

    bundles = %{bundle.id => bundle}

    stored_opts =
      [format: :stored, contracts: references, contract_bundles: bundles]
      |> Keyword.merge(opts)

    decoded =
      flow
      |> Jido.Flow.to_map(stored_opts)
      |> JSON.encode!()
      |> JSON.decode!()

    assert {:ok, loaded} = Jido.Flow.from_map(decoded, contract_bundles: bundles)

    {decoded, loaded}
  end

  defp flow_action_registry(namespace) do
    %{
      "#{namespace}/add/v1" => Add,
      "#{namespace}/multiply/v1" => Multiply,
      "#{namespace}/echo-params/v1" => EchoParamsAction
    }
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
        expected: %{value: 8}
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
        label: "shaped-return",
        module_suffix: "ShapedReturnFlow",
        module: &create_shaped_return_flow_module/1,
        opts: [
          name: "shaped_return_flow",
          description: "Returns a composite expression"
        ],
        syntax: &FlowFixtures.shaped_return_syntax/0,
        builder: &FlowFixtures.shaped_return_builder/0,
        source: &FlowFixtures.shaped_return_source/0,
        canonical: &FlowFixtures.shaped_return_canonical_map/0,
        input: %{value: 3},
        context: %{trace_id: "trace-1"},
        expected: %{
          sum: 4,
          product: 8,
          original: 3,
          trace_id: "trace-1",
          literal: "ok",
          nested: [8]
        }
      },
      %{
        label: "derived-name",
        module_suffix: "DerivedNameFlow",
        module: &create_derived_name_flow_module/1,
        opts: [
          name: "derived_name_flow",
          description: "Derives node names from bindings"
        ],
        syntax: &FlowFixtures.derived_name_syntax/0,
        builder: &FlowFixtures.derived_name_builder/0,
        source: &FlowFixtures.derived_name_source/0,
        canonical: &FlowFixtures.derived_name_canonical_map/0,
        input: %{value: 3},
        expected: %{value: 8}
      },
      %{
        label: "annotated",
        module_suffix: "AnnotatedFlow",
        module: &create_annotated_flow_module/1,
        opts: [
          name: "annotated_flow",
          description: "Annotates a step without changing semantics"
        ],
        syntax: &FlowFixtures.annotated_syntax/0,
        builder: &FlowFixtures.annotated_builder/0,
        source: &FlowFixtures.annotated_source/0,
        canonical: &FlowFixtures.annotated_canonical_map/0,
        input: %{value: 3},
        expected: %{value: 4}
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
        expected: %{total: 42}
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
        label: "fan-in",
        module_suffix: "FanInFlow",
        module: &create_fan_in_flow_module/1,
        opts: [
          name: "fan_in_flow",
          description: "Merges sibling branches through a dependency join"
        ],
        syntax: &FlowFixtures.fan_in_syntax/0,
        builder: &FlowFixtures.fan_in_builder/0,
        source: &FlowFixtures.fan_in_source/0,
        canonical: &FlowFixtures.fan_in_canonical_map/0,
        input: %{id: "item-1", base: "root"},
        expected: %{left: "left", right: "right", id: "item-1"}
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

          return result(:double)
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
      },
      %{
        label: "annotated",
        source: FlowFixtures.annotated_source(),
        opts: [
          name: "annotated_flow",
          description: "Annotates a step without changing semantics"
        ],
        formatted_source: """
        flow do
          added =
            step :add_one,
              JidoTest.TestActions.Add,
              note: "Visible only in provenance",
              tags: [
                :math,
                "example"
              ],
              label: "Add one",
              with: %{
                amount: value(1),
                value: input(:value)
              }

          return added
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

        return(result(:double))
      end
    )
  end

  defp choice_syntax do
    Syntax.new(name: "choice_parity")
    |> Syntax.choice(
      :route,
      [
        Syntax.option(
          :priority,
          Syntax.eq(Syntax.input(:kind), Syntax.value(:priority)),
          Add,
          %{value: Syntax.input(:value), amount: Syntax.value(1)}
        ),
        Syntax.option(
          :other,
          Syntax.neq(Syntax.input(:kind), Syntax.value(:priority)),
          Multiply,
          %{value: Syntax.input(:value), amount: Syntax.value(2)}
        )
      ],
      Syntax.fallback(Add, %{value: Syntax.input(:value), amount: Syntax.value(0)})
    )
    |> Syntax.return(Syntax.result(:route))
  end

  defp choice_builder do
    Builder.new(name: "choice_parity")
    |> Builder.choice(
      :route,
      [
        Builder.option(
          :priority,
          Builder.eq(Builder.input(:kind), Builder.value(:priority)),
          Add,
          %{value: Builder.input(:value), amount: Builder.value(1)}
        ),
        Builder.option(
          :other,
          Builder.neq(Builder.input(:kind), Builder.value(:priority)),
          Multiply,
          %{value: Builder.input(:value), amount: Builder.value(2)}
        )
      ],
      Builder.fallback(Add, %{value: Builder.input(:value), amount: Builder.value(0)})
    )
    |> Builder.return(Builder.result(:route))
  end

  defp choice_source do
    """
    flow do
      routed = choose :route do
        option :priority,
          when: eq(input(:kind), value(:priority)),
          run: JidoTest.TestActions.Add,
          with: %{value: input(:value), amount: value(1)}

        option :other,
          when: neq(input(:kind), value(:priority)),
          run: JidoTest.TestActions.Multiply,
          with: %{value: input(:value), amount: value(2)}

        otherwise run: JidoTest.TestActions.Add, with: %{value: input(:value), amount: value(0)}
      end

      return routed
    end
    """
  end

  defp choice_stored_source do
    """
    flow do
      routed = choose :route do
        option :priority,
          when: eq(input(:kind), value(:priority)),
          run: "add",
          with: %{value: input(:value), amount: value(1)}

        option :other,
          when: neq(input(:kind), value(:priority)),
          run: "multiply",
          with: %{value: input(:value), amount: value(2)}

        otherwise run: "add", with: %{value: input(:value), amount: value(0)}
      end

      return routed
    end
    """
  end

  defp map_reduce_syntax do
    Syntax.new(name: "map_reduce_parity")
    |> Syntax.map(
      :enrich,
      Syntax.input(:items),
      Add,
      %{
        value: Syntax.item(:value),
        amount: Syntax.value(1),
        index: Syntax.item_index(),
        item_id: Syntax.item_id()
      },
      on_error: :collect_errors,
      bind: :mapped
    )
    |> Syntax.reduce(
      :summarize,
      Syntax.binding(:mapped),
      Syntax.value(%{value: 1}),
      Multiply,
      %{
        value: Syntax.accumulator(:value),
        amount: Syntax.item(:value),
        item_id: Syntax.item_id()
      },
      bind: :summary,
      after: :enrich
    )
    |> Syntax.return(Syntax.binding(:summary))
  end

  defp map_reduce_builder do
    Builder.new(name: "map_reduce_parity")
    |> Builder.map(
      :enrich,
      Builder.input(:items),
      Add,
      %{
        value: Builder.item(:value),
        amount: Builder.value(1),
        index: Builder.item_index(),
        item_id: Builder.item_id()
      },
      on_error: :collect_errors,
      bind: :mapped
    )
    |> Builder.reduce(
      :summarize,
      Builder.binding(:mapped),
      Builder.value(%{value: 1}),
      Multiply,
      %{
        value: Builder.accumulator(:value),
        amount: Builder.item(:value),
        item_id: Builder.item_id()
      },
      bind: :summary,
      after: :enrich
    )
    |> Builder.return(Builder.binding(:summary))
  end

  defp map_reduce_source do
    """
    flow do
      mapped = map :enrich, input(:items),
        run: JidoTest.TestActions.Add,
        with: %{value: item(:value), amount: value(1), index: item_index(), item_id: item_id()},
        on_error: :collect_errors

      summary = reduce :summarize, mapped,
        initial: value(%{value: 1}),
        run: JidoTest.TestActions.Multiply,
        with: %{value: accumulator(:value), amount: item(:value), item_id: item_id()},
        after: :enrich

      return summary
    end
    """
  end

  defp map_reduce_stored_source do
    """
    flow do
      mapped = map "enrich", input(:items),
        run: "add",
        with: %{value: item(:value), amount: value(1), index: item_index(), item_id: item_id()},
        on_error: :collect_errors

      summary = reduce "summarize", mapped,
        initial: value(%{value: 1}),
        run: "multiply",
        with: %{value: accumulator(:value), amount: item(:value), item_id: item_id()},
        after: "enrich"

      return summary
    end
    """
  end

  defp create_map_reduce_flow_module(prefix) do
    create_flow_module(
      prefix,
      "map_reduce_parity",
      nil,
      quote do
        mapped =
          map(:enrich, input(:items),
            run: unquote(Add),
            with: %{
              value: item(:value),
              amount: value(1),
              index: item_index(),
              item_id: item_id()
            },
            on_error: :collect_errors
          )

        summary =
          reduce(:summarize, mapped,
            initial: value(%{value: 1}),
            run: unquote(Multiply),
            with: %{
              value: accumulator(:value),
              amount: item(:value),
              item_id: item_id()
            },
            after: :enrich
          )

        return(summary)
      end
    )
  end

  defp create_choice_flow_module(prefix) do
    create_flow_module(
      prefix,
      "choice_parity",
      nil,
      quote do
        routed =
          choose :route do
            option(:priority,
              when: eq(input(:kind), value(:priority)),
              run: unquote(Add),
              with: %{value: input(:value), amount: value(1)}
            )

            option(:other,
              when: neq(input(:kind), value(:priority)),
              run: unquote(Multiply),
              with: %{value: input(:value), amount: value(2)}
            )

            otherwise(run: unquote(Add), with: %{value: input(:value), amount: value(0)})
          end

        return(routed)
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

  defp create_annotated_flow_module(prefix) do
    create_flow_module(
      prefix,
      "annotated_flow",
      "Annotates a step without changing semantics",
      quote do
        added =
          step(:add_one, unquote(Add),
            with: %{value: input(:value), amount: value(1)},
            label: "Add one",
            tags: [:math, "example"],
            note: "Visible only in provenance"
          )

        return(added)
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
            with: %{
              quote: %{
                id: input(:quote_id),
                pricing: %{total: input([:items, 0, :price])}
              },
              tags: [input(:tag)]
            }
          )

        audit =
          step(:audit_quote, unquote(EchoParamsAction),
            with: %{
              quote_id: select(loaded, [:quote, :id]),
              total: select(select(loaded, [:quote, :pricing]), :total),
              first_item_id: select(input(:items), [0, :id]),
              tag: select(loaded, [:tags, 0])
            }
          )

        return(%{total: select(audit, :total)})
      end
    )
  end

  defp create_shaped_return_flow_module(prefix) do
    create_flow_module(
      prefix,
      "shaped_return_flow",
      "Returns a composite expression",
      quote do
        added =
          step(:add_one, unquote(Add), with: %{value: input(:value), amount: value(1)})

        doubled =
          step(:double, unquote(Multiply),
            with: %{value: select(added, :value), amount: value(2)}
          )

        return(%{
          sum: select(added, :value),
          product: select(doubled, :value),
          original: input(:value),
          trace_id: context(:trace_id),
          literal: "ok",
          nested: [select(doubled, :value)]
        })
      end
    )
  end

  defp create_derived_name_flow_module(prefix) do
    create_flow_module(
      prefix,
      "derived_name_flow",
      "Derives node names from bindings",
      quote do
        added =
          step(unquote(Add), with: %{value: input(:value), amount: value(1)})

        doubled =
          step(unquote(Multiply), with: %{value: select(added, :value), amount: value(2)})

        return(doubled)
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
          step(:load_quote, unquote(EchoParamsAction), with: %{id: input(:quote_id)})

        step(:independent, unquote(EchoParamsAction), with: %{event: "side"})

        audit =
          step(:audit_quote, unquote(EchoParamsAction),
            with: %{event: "quoted"},
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
            with: %{
              user_id: input(:user_id),
              input_trace_id: input(:trace_id),
              context_trace_id: context(:trace_id),
              tenant_id: select(context(:tenant), :id)
            }
          )

        return(audit)
      end
    )
  end

  defp create_fan_in_flow_module(prefix) do
    create_flow_module(
      prefix,
      "fan_in_flow",
      "Merges sibling branches through a dependency join",
      quote do
        loaded =
          step(:load, unquote(EchoParamsAction),
            with: %{
              id: input(:id),
              base: input(:base)
            }
          )

        left_branch =
          step(:left, unquote(EchoParamsAction),
            with: %{
              side: "left",
              id: select(loaded, :id)
            }
          )

        right_branch =
          step(:right, unquote(EchoParamsAction),
            with: %{
              side: "right",
              base: select(loaded, :base)
            }
          )

        merged =
          step(:merge, unquote(EchoParamsAction),
            with: %{
              left: select(left_branch, :side),
              right: select(right_branch, :side),
              id: select(left_branch, :id)
            }
          )

        return(merged)
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
            with: %{
              cart_id: input(:cart_id),
              items: input(:items)
            }
          )

        group do
          branch :alpha do
            priced =
              step(:price_cart, unquote(EchoParamsAction),
                with: %{
                  cart_id: select(cart, :cart_id),
                  total: input(:total)
                }
              )

            step(:audit_price, unquote(EchoParamsAction),
              with: %{event: "priced"},
              after: priced
            )
          end

          branch :beta do
            reserved =
              step(:reserve_inventory, unquote(EchoParamsAction),
                with: %{
                  cart_id: select(cart, :cart_id),
                  items: select(cart, :items)
                }
              )
          end
        end

        step(:post_group_independent, unquote(EchoParamsAction), with: %{event: "side"})

        final =
          step(:finalize, unquote(EchoParamsAction),
            with: %{
              priced: priced,
              reserved: reserved
            }
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
    |> Syntax.return(Syntax.result(:"add_#{length(amounts)}"))
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
    |> Builder.return(Builder.result(:"add_#{length(amounts)}"))
  end
end
