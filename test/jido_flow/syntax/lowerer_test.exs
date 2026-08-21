defmodule Jido.Flow.Syntax.LowererTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Action.Error.InvalidInputError
  alias Jido.Flow
  alias Jido.Flow.ContractBundle
  alias Jido.Flow.Ref
  alias Jido.Flow.Syntax
  alias Jido.Flow.Syntax.Lowerer
  alias JidoTest.FlowFixtures
  alias JidoTest.TestActions.{Add, EchoParamsAction, Multiply}

  defmodule TrustedLiteral do
    @enforce_keys [:id]
    defstruct [:id]
  end

  describe "syntax lowerer" do
    test "lowers a named if else choice with a result binding" do
      syntax =
        Syntax.new(name: "choice")
        |> Syntax.choice(
          :route,
          [
            Syntax.option(
              :fast,
              Syntax.eq(Syntax.input(:mode), Syntax.value("fast")),
              Add,
              %{value: Syntax.input(:value)}
            )
          ],
          Syntax.fallback(EchoParamsAction, %{value: Syntax.input(:value)}),
          bind: :routed
        )
        |> Syntax.return(Syntax.binding(:routed))

      assert {:ok, flow} = Lowerer.lower(syntax)
      assert [%{kind: :choice, name: "route", deps: []}] = Flow.to_map(flow).nodes
      assert Flow.to_map(flow).return == %{type: :result, node: "route", path: []}
    end

    test "unites explicit and derived choice dependencies and binds its result for later steps" do
      syntax =
        Syntax.new(name: "choice_deps")
        |> Syntax.step(:load, Add, %{value: Syntax.input(:value)}, bind: :loaded)
        |> Syntax.choice(
          :route,
          [
            Syntax.option(
              :match,
              Syntax.eq(Syntax.binding(:loaded), Syntax.value(%{value: 1})),
              EchoParamsAction,
              %{selected: Syntax.binding(:loaded)}
            )
          ],
          Syntax.fallback(EchoParamsAction, %{selected: Syntax.result(:load)}),
          bind: :routed,
          after: [:load, Syntax.binding(:loaded)]
        )
        |> Syntax.step(:consume, EchoParamsAction, %{selected: Syntax.binding(:routed)})
        |> Syntax.return(Syntax.result(:consume))

      assert {:ok, flow} = Lowerer.lower(syntax)
      assert [_load, route, consume] = Flow.to_map(flow).nodes
      assert route.name == "route"
      assert route.deps == ["load"]
      assert consume.deps == ["route"]
    end

    test "reports choice source context for invalid option forms" do
      base = Syntax.new(name: "bad_choice")

      cases = [
        {base
         |> Syntax.choice(
           :route,
           [
             Syntax.option(
               :duplicate,
               Syntax.eq(Syntax.input(:mode), Syntax.value("one")),
               Add,
               %{}
             ),
             Syntax.option(
               :duplicate,
               Syntax.eq(Syntax.input(:mode), Syntax.value("two")),
               Add,
               %{}
             )
           ],
           Syntax.fallback(Add, %{})
         )
         |> Syntax.return(Syntax.result(:route)), "duplicate choice option name"},
        {base
         |> Syntax.choice(
           :route,
           [Syntax.option(:match, Syntax.eq(Syntax.input(:mode), Syntax.value("one")), Add, %{})],
           nil
         )
         |> Syntax.return(Syntax.result(:route)), "choice fallback is required"},
        {base
         |> Syntax.choice(
           :route,
           [Syntax.option(:match, %Syntax.Condition{operator: :unknown, operands: []}, Add, %{})],
           Syntax.fallback(Add, %{})
         )
         |> Syntax.return(Syntax.result(:route)), "unsupported choice condition operator"},
        {base
         |> Syntax.choice(
           :route,
           [
             Syntax.option(
               :match,
               Syntax.eq(Syntax.input(:mode), Syntax.value("one")),
               "not_a_module",
               %{}
             )
           ],
           Syntax.fallback(Add, %{})
         )
         |> Syntax.return(Syntax.result(:route)), "choice option target must be a module atom"}
      ]

      for {syntax, expected_message} <- cases do
        assert {:error, %InvalidInputError{message: message, details: details}} =
                 Lowerer.lower(syntax)

        assert message =~ expected_message
        assert details.choice == "route"
      end
    end

    test "prevents choice binding aliases from colliding with source node names" do
      syntax =
        Syntax.new(name: "choice_namespace")
        |> Syntax.group([
          Syntax.branch(:prepare, [
            Syntax.operation(:step, %{name: :load, action: Add, input: %{}})
          ])
        ])
        |> Syntax.choice(
          :route,
          [Syntax.option(:match, Syntax.eq(Syntax.input(:mode), Syntax.value("one")), Add, %{})],
          Syntax.fallback(Add, %{}),
          bind: :load
        )
        |> Syntax.return(Syntax.result(:load))

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Lowerer.lower(syntax)

      assert message =~ "binding alias conflicts with step name"
      assert details.binding == :load
    end

    test "lowers the first milestone operations to the expected canonical map" do
      assert {:ok, flow} = Lowerer.lower(FlowFixtures.math_syntax())
      assert Flow.to_map(flow) == FlowFixtures.math_canonical_map()
    end

    test "rejects unsupported syntax operations with the operation kind" do
      syntax =
        Syntax.new(name: "bad")
        |> Syntax.add(Syntax.operation(:choose, branches: []))

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Lowerer.lower(syntax)

      assert message =~ "unsupported flow syntax operation"
      assert details.kind == :choose
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

    test "rejects malformed operation collections" do
      syntax =
        Syntax.new(name: "bad")
        |> Map.put(:operations, :not_operations)

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Lowerer.lower(syntax)

      assert message =~ "flow syntax operations must be a list"
      assert details.operations == :not_operations
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
      assert details.step == "double"
      assert details.dependency == "add_one"
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

    test "rejects duplicate return declarations" do
      syntax =
        Syntax.new(name: "duplicate_return")
        |> Syntax.step(:first, Add, %{value: Syntax.input(:value)})
        |> Syntax.step(:second, Add, %{value: Syntax.input(:value)})
        |> Syntax.return(Syntax.result(:first))
        |> Syntax.return(Syntax.result(:second))

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Lowerer.lower(syntax)

      assert message =~ "duplicate return declaration"
      assert details.operation == :return
    end

    test "rejects returns that do not reference result refs" do
      syntax =
        Syntax.new(name: "bad")
        |> Syntax.step(:add_one, Add, %{value: Syntax.input(:value)})
        |> Syntax.return(Syntax.value(:not_a_result))

      assert {:error, %InvalidInputError{message: message}} = Lowerer.lower(syntax)
      assert message =~ "return must reference at least one step result"
    end

    test "accepts structured maps whose leaves are supported refs or literals" do
      syntax =
        Syntax.new(name: "structured")
        |> Syntax.step(:add_one, Add, %{
          nested: %{
            input: Syntax.input([:payload, :value]),
            context: Syntax.context(:trace_id),
            literal: Syntax.value(%{amount: 1})
          }
        })
        |> Syntax.return(Syntax.result(:add_one))

      assert {:ok, flow} = Lowerer.lower(syntax)
      assert [node] = Flow.to_map(flow).nodes

      assert node.input.nested == %{
               input: %{type: :input, path: [:payload, :value]},
               context: %{type: :context, path: [:trace_id]},
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

    test "direct user structs match explicit values across steps, lists, and return" do
      literal = %TrustedLiteral{id: "trusted"}

      direct =
        Syntax.new(name: "trusted_struct")
        |> Syntax.step(:direct, EchoParamsAction, literal)
        |> Syntax.step(:nested, EchoParamsAction, %{
          prior: Syntax.result(:direct),
          values: [literal]
        })
        |> Syntax.return(%{result: Syntax.result(:nested), literal: literal})

      explicit =
        Syntax.new(name: "trusted_struct")
        |> Syntax.step(:direct, EchoParamsAction, Syntax.value(literal))
        |> Syntax.step(:nested, EchoParamsAction, %{
          prior: Syntax.result(:direct),
          values: [Syntax.value(literal)]
        })
        |> Syntax.return(%{
          result: Syntax.result(:nested),
          literal: Syntax.value(literal)
        })

      assert {:ok, direct_flow} = Lowerer.lower(direct)
      assert {:ok, explicit_flow} = Lowerer.lower(explicit)
      assert Flow.to_map(direct_flow) == Flow.to_map(explicit_flow)

      assert [direct_node, nested_node] = direct_flow.nodes
      assert direct_node.input == Ref.value(literal)
      assert nested_node.input.values == [Ref.value(literal)]
      assert direct_flow.return.literal == Ref.value(literal)

      bundle =
        ContractBundle.new!(
          id: "bundle/v1",
          schemas: %{"input/v1" => [], "output/v1" => []},
          action_registries: %{"actions/v1" => %{"echo" => EchoParamsAction}}
        )

      assert_raise InvalidInputError, ~r/stored flow value contains unsupported struct/, fn ->
        Flow.to_map(direct_flow,
          format: :stored,
          contracts: %{
            bundle: "bundle/v1",
            input_schema: "input/v1",
            output_schema: "output/v1",
            action_registry: "actions/v1"
          },
          contract_bundles: %{"bundle/v1" => bundle}
        )
      end
    end

    test "accepts canonical refs and literal leaves in syntax input" do
      syntax =
        Syntax.new(name: "canonical_refs")
        |> Syntax.step(:add_one, Add, %{value: Syntax.input(:value)})
        |> Syntax.step(:double, Multiply, %{
          value: Ref.result(:add_one, :value),
          amount: Ref.value(2),
          passthrough: Ref.input(:value),
          literal: 10
        })
        |> Syntax.return(Syntax.result(:double, :value))

      assert {:ok, flow} = Lowerer.lower(syntax)
      assert [_add_one, double] = Flow.to_map(flow).nodes

      assert double.input.value == %{type: :result, node: "add_one", path: [:value]}
      assert double.input.amount == %{type: :value, value: 2}
      assert double.input.passthrough == %{type: :input, path: [:value]}
      assert double.input.literal == %{type: :value, value: 10}
    end

    test "lowers select expressions inside maps to canonical refs and structures" do
      syntax =
        Syntax.new(name: "projection")
        |> Syntax.step(
          :load_quote,
          EchoParamsAction,
          %{
            quote: %{
              id: Syntax.input(:quote_id),
              pricing: %{total: Syntax.input([:items, 0, :price])}
            },
            tags: [Syntax.input(:tag)]
          },
          bind: :loaded
        )
        |> Syntax.step(
          :audit_quote,
          EchoParamsAction,
          %{
            quote_id: Syntax.select(Syntax.binding(:loaded), [:quote, :id]),
            total:
              Syntax.select(
                Syntax.select(Syntax.binding(:loaded), [:quote, :pricing]),
                :total
              ),
            first_item_id: Syntax.select(Syntax.input(:items), [0, :id]),
            tenant_id: Syntax.select(Syntax.context(:tenant), :id),
            trace_id: Syntax.context(:trace_id),
            tag: Syntax.select(Syntax.binding(:loaded), [:tags, 0])
          },
          bind: :audit
        )
        |> Syntax.return(Syntax.select(Syntax.binding(:audit), :total))

      assert {:ok, flow} = Lowerer.lower(syntax)
      assert [load_quote, audit_quote] = Flow.to_map(flow).nodes

      assert load_quote.input == %{
               quote: %{
                 id: %{type: :input, path: [:quote_id]},
                 pricing: %{total: %{type: :input, path: [:items, 0, :price]}}
               },
               tags: [%{type: :input, path: [:tag]}]
             }

      assert audit_quote.input == %{
               quote_id: %{type: :result, node: "load_quote", path: [:quote, :id]},
               total: %{
                 type: :result,
                 node: "load_quote",
                 path: [:quote, :pricing, :total]
               },
               first_item_id: %{type: :input, path: [:items, 0, :id]},
               tenant_id: %{type: :context, path: [:tenant, :id]},
               trace_id: %{type: :context, path: [:trace_id]},
               tag: %{type: :result, node: "load_quote", path: [:tags, 0]}
             }

      assert audit_quote.deps == ["load_quote"]
      assert Flow.to_map(flow).return == %{type: :result, node: "audit_quote", path: [:total]}
      refute Flow.to_map(flow) |> inspect() |> String.contains?("select")
    end

    test "rejects select over non-projectable sources" do
      syntax =
        Syntax.new(name: "bad_select")
        |> Syntax.step(:echo, EchoParamsAction, %{
          value: Syntax.select(Syntax.value(%{id: 1}), :id)
        })
        |> Syntax.return(Syntax.result(:echo))

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Lowerer.lower(syntax)

      assert message =~ "select source must resolve to an input, context, or result ref"
      assert details.step == "echo"
      assert details.type == :value
    end

    test "rejects select over map or list sources" do
      cases = [
        {%{id: Syntax.input(:id)}, :map},
        {[Syntax.input(:id)], :list}
      ]

      for {source, type} <- cases do
        syntax =
          Syntax.new(name: "bad_structured_select")
          |> Syntax.step(:echo, EchoParamsAction, %{value: Syntax.select(source, :id)})
          |> Syntax.return(Syntax.result(:echo))

        assert {:error, %InvalidInputError{message: message, details: details}} =
                 Lowerer.lower(syntax)

        assert message =~ "select source must resolve to an input, context, or result ref"
        assert details.step == "echo"
        assert details.type == type
      end
    end

    test "rejects unsupported syntax expression types" do
      syntax =
        Syntax.new(name: "bad_expr")
        |> Syntax.step(:echo, EchoParamsAction, %{value: %Syntax.Expr{type: :unknown}})
        |> Syntax.return(Syntax.result(:echo))

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Lowerer.lower(syntax)

      assert message =~ "unsupported flow syntax expression"
      assert details.step == "echo"
      assert details.type == :unknown
    end

    test "rejects invalid select path segments before runtime" do
      cases = [
        {Syntax.select(Syntax.input(:payload), %{bad: :path}), [:payload, %{bad: :path}]},
        {Syntax.select(Syntax.input(:payload), [nil]), [:payload, nil]}
      ]

      for {expr, path} <- cases do
        syntax =
          Syntax.new(name: "bad_select_path")
          |> Syntax.step(:echo, EchoParamsAction, %{value: expr})
          |> Syntax.return(Syntax.result(:echo))

        assert {:error, %InvalidInputError{message: message, details: details}} =
                 Lowerer.lower(syntax)

        assert message =~ "select path segments must be atoms, strings, or integers"
        assert details.step == "echo"
        assert details.path == path
      end
    end

    test "lowers structured return values with result refs" do
      syntax =
        Syntax.new(name: "structured_return")
        |> Syntax.step(:echo, EchoParamsAction, %{total: Syntax.input(:total)}, bind: :echoed)
        |> Syntax.return(%{
          total: Syntax.select(Syntax.binding(:echoed), :total),
          original: Syntax.input(:total),
          literal: "ok"
        })

      assert {:ok, flow} = Lowerer.lower(syntax)

      assert Flow.to_map(flow).return == %{
               total: %{type: :result, node: "echo", path: [:total]},
               original: %{type: :input, path: [:total]},
               literal: %{type: :value, value: "ok"}
             }
    end

    test "rejects return values without result refs" do
      syntax =
        Syntax.new(name: "constant_return")
        |> Syntax.step(:echo, EchoParamsAction, %{total: Syntax.input(:total)})
        |> Syntax.return(%{total: Syntax.input(:total), literal: "ok"})

      assert {:error, %InvalidInputError{message: message}} = Lowerer.lower(syntax)
      assert message =~ "return must reference at least one step result"
    end

    test "stops lowering lists when an item references an unbound result" do
      syntax =
        Syntax.new(name: "bad_list")
        |> Syntax.step(:double, Multiply, %{
          values: [Syntax.value(1), Syntax.result(:missing, :value)]
        })
        |> Syntax.return(Syntax.result(:double, :value))

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Lowerer.lower(syntax)

      assert message =~ "result reference before it is bound"
      assert details.step == "double"
      assert details.dependency == "missing"
    end

    test "lowers binding handles to result refs and keeps aliases in provenance only" do
      syntax =
        Syntax.new(name: "binding_flow")
        |> Syntax.step(:add_one, Add, %{value: Syntax.input(:value)},
          bind: :added,
          provenance: %{line: 10}
        )
        |> Syntax.step(:double, Multiply, Syntax.binding(:added), bind: :doubled)
        |> Syntax.step(:triple, Multiply, %{
          value: Syntax.binding(:added),
          amount: Syntax.value(3)
        })
        |> Syntax.return(Syntax.binding(:doubled))

      assert {:ok, flow} = Lowerer.lower(syntax)

      semantic_map = Flow.to_map(flow)
      refute inspect(semantic_map) =~ "added"
      refute inspect(semantic_map) =~ "doubled"

      assert [_add_one, double, triple] = semantic_map.nodes
      assert double.input == %{type: :result, node: "add_one", path: []}
      assert double.deps == ["add_one"]
      assert triple.input.value == %{type: :result, node: "add_one", path: []}
      assert semantic_map.return == %{type: :result, node: "double", path: []}

      provenance_map = Flow.to_map(flow, provenance: true)
      assert [add_one_provenance, double_provenance, _triple_provenance] = provenance_map.nodes
      assert add_one_provenance.provenance.binding == :added
      assert add_one_provenance.provenance.line == 10
      assert double_provenance.provenance.binding == :doubled
    end

    test "derives a missing step name from its binding" do
      syntax =
        Syntax.new(name: "derived_binding_name")
        |> Syntax.step(nil, Add, %{value: Syntax.input(:value), amount: Syntax.value(1)},
          bind: :added
        )
        |> Syntax.return(Syntax.binding(:added))

      assert {:ok, flow} = Lowerer.lower(syntax)

      assert [%{name: "added", provenance: %{binding: :added}}] =
               Flow.to_map(flow, provenance: true).nodes

      assert Flow.to_map(flow).return == %{type: :result, node: "added", path: []}
    end

    test "rejects an unnamed step without a binding" do
      syntax =
        Syntax.new(name: "unnamed")
        |> Syntax.step(nil, Add, %{value: Syntax.input(:value)})
        |> Syntax.return(Syntax.result(:missing))

      assert {:error, %InvalidInputError{message: message}} = Lowerer.lower(syntax)
      assert message =~ "step requires a name or a binding"
    end

    test "rejects a derived name that duplicates an explicit step name" do
      syntax =
        Syntax.new(name: "duplicate_derived_name")
        |> Syntax.step(:added, Add, %{value: Syntax.input(:value)})
        |> Syntax.step(nil, Multiply, %{value: Syntax.input(:value)}, bind: :added)
        |> Syntax.return(Syntax.result(:added))

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Lowerer.lower(syntax)

      assert message =~ "duplicate step name"
      assert details.name == "added"
    end

    test "keeps step annotations in provenance only" do
      annotated =
        Syntax.new(name: "annotated_flow")
        |> Syntax.step(:add_one, Add, %{value: Syntax.input(:value)},
          bind: :added,
          label: "Add one",
          tags: [:math, "example"],
          note: "Visible only in provenance",
          provenance: %{line: 12}
        )
        |> Syntax.return(Syntax.binding(:added))

      unannotated =
        Syntax.new(name: "annotated_flow")
        |> Syntax.step(:add_one, Add, %{value: Syntax.input(:value)})
        |> Syntax.return(Syntax.result(:add_one))

      assert {:ok, annotated_flow} = Lowerer.lower(annotated)
      assert {:ok, unannotated_flow} = Lowerer.lower(unannotated)

      assert Flow.to_map(annotated_flow) == Flow.to_map(unannotated_flow)

      assert [%{provenance: provenance}] = Flow.to_map(annotated_flow, provenance: true).nodes
      assert provenance.line == 12
      assert provenance.binding == :added
      assert provenance.label == "Add one"
      assert provenance.tags == ["math", "example"]
      assert provenance.note == "Visible only in provenance"
    end

    test "keeps step annotations alongside branch provenance" do
      syntax =
        Syntax.new(name: "annotated_branch")
        |> Syntax.group([
          Syntax.branch(:alpha, [
            step_operation(:price_cart, EchoParamsAction, %{},
              label: "Price cart",
              tags: [:pricing]
            )
          ])
        ])
        |> Syntax.return(Syntax.result(:price_cart))

      assert {:ok, flow} = Lowerer.lower(syntax)
      assert [%{provenance: provenance}] = Flow.to_map(flow, provenance: true).nodes
      assert provenance.branch == :alpha
      assert provenance.label == "Price cart"
      assert provenance.tags == ["pricing"]
    end

    test "rejects invalid step annotation values" do
      cases = [
        {:label, %{label: :not_a_string}, "step annotation label must be a string"},
        {:note, %{note: [:not, :a, :string]}, "step annotation note must be a string"},
        {:tags, %{tags: :not_a_list}, "step annotation tags must be a list"},
        {:tags, %{tags: ["ok", 123]}, "step annotation tags must be strings or atoms"}
      ]

      for {field, provenance, expected_message} <- cases do
        syntax =
          Syntax.new(name: "bad_annotation")
          |> Syntax.add(
            Syntax.operation(
              :step,
              %{name: "add_one", action: Add, input: %{}},
              provenance: provenance
            )
          )
          |> Syntax.return(Syntax.result(:add_one))

        assert {:error, %InvalidInputError{message: message, details: details}} =
                 Lowerer.lower(syntax)

        assert message =~ expected_message
        assert details.step == "add_one"
        assert details.field == field
      end
    end

    test "lowers explicit after targets to canonical deps without source-order deps" do
      syntax =
        Syntax.new(name: "explicit_edges")
        |> Syntax.step(:load_cart, EchoParamsAction, %{cart_id: Syntax.input(:cart_id)},
          bind: :cart_handle
        )
        |> Syntax.step(:independent, EchoParamsAction, %{event: "side"})
        |> Syntax.step(
          :audit_cart,
          EchoParamsAction,
          %{event: "loaded"},
          after: [:load_cart, Syntax.binding(:cart_handle), :load_cart]
        )
        |> Syntax.return(Syntax.result(:audit_cart))

      assert {:ok, flow} = Lowerer.lower(syntax)
      assert [load_cart, independent, audit_cart] = Flow.to_map(flow).nodes

      assert load_cart.deps == []
      assert independent.deps == []
      assert audit_cart.deps == ["load_cart"]
      assert audit_cart.input == %{event: %{type: :value, value: "loaded"}}
      refute inspect(Flow.to_map(flow)) =~ "cart_handle"
    end

    test "dedupes explicit after targets with implicit data dependencies" do
      syntax =
        Syntax.new(name: "deduped_edges")
        |> Syntax.step(:load_quote, EchoParamsAction, %{id: Syntax.input(:quote_id)},
          bind: :quote
        )
        |> Syntax.step(
          :audit_quote,
          EchoParamsAction,
          %{quote_id: Syntax.select(Syntax.binding(:quote), :id)},
          after: Syntax.binding(:quote)
        )
        |> Syntax.return(Syntax.result(:audit_quote))

      assert {:ok, flow} = Lowerer.lower(syntax)
      assert [_load_quote, audit_quote] = Flow.to_map(flow).nodes

      assert audit_quote.deps == ["load_quote"]

      assert audit_quote.input.quote_id == %{
               type: :result,
               node: "load_quote",
               path: [:id]
             }
    end

    test "treats an explicit nil after attr as empty deps" do
      syntax =
        Syntax.new(name: "nil_after")
        |> Syntax.add(
          Syntax.operation(:step, %{
            name: :audit,
            action: EchoParamsAction,
            input: %{},
            after: nil
          })
        )
        |> Syntax.return(Syntax.result(:audit))

      assert {:ok, flow} = Lowerer.lower(syntax)
      assert [%{deps: []}] = Flow.to_map(flow).nodes
    end

    test "lowers branch groups to ordinary nodes without implicit sibling or barrier deps" do
      syntax =
        Syntax.new(name: "branching")
        |> Syntax.step(:load_cart, EchoParamsAction, %{cart_id: Syntax.input(:cart_id)},
          bind: :cart
        )
        |> Syntax.group([
          Syntax.branch(:alpha, [
            step_operation(:price_cart, EchoParamsAction, Syntax.binding(:cart), bind: :priced),
            step_operation(
              :audit_price,
              EchoParamsAction,
              %{event: "priced"},
              after: Syntax.binding(:priced)
            )
          ]),
          Syntax.branch(:beta, [
            step_operation(:reserve_inventory, EchoParamsAction, Syntax.binding(:cart),
              bind: :reserved
            )
          ])
        ])
        |> Syntax.step(
          :finalize,
          EchoParamsAction,
          %{
            priced: Syntax.binding(:priced),
            reserved: Syntax.binding(:reserved)
          },
          bind: :final
        )
        |> Syntax.step(:post_group_independent, EchoParamsAction, %{event: "side"})
        |> Syntax.return(Syntax.binding(:final))

      assert {:ok, flow} = Lowerer.lower(syntax)

      nodes_by_name = Map.new(Flow.to_map(flow).nodes, fn node -> {node.name, node} end)

      assert nodes_by_name["load_cart"].deps == []
      assert nodes_by_name["price_cart"].deps == ["load_cart"]
      assert nodes_by_name["audit_price"].deps == ["price_cart"]
      assert nodes_by_name["reserve_inventory"].deps == ["load_cart"]
      assert nodes_by_name["finalize"].deps == ["price_cart", "reserve_inventory"]
      assert nodes_by_name["post_group_independent"].deps == []

      semantic_map = Flow.to_map(flow)
      refute inspect(semantic_map) =~ "alpha"
      refute inspect(semantic_map) =~ "beta"

      provenance_map = Flow.to_map(flow, provenance: true)

      assert [
               %{name: "load_cart"},
               %{name: "post_group_independent", provenance: %{}},
               %{name: "price_cart", provenance: %{branch: :alpha}},
               %{name: "reserve_inventory", provenance: %{branch: :beta}},
               %{name: "audit_price", provenance: %{branch: :alpha}},
               %{name: "finalize"}
             ] = provenance_map.nodes
    end

    test "rejects sibling branch dependencies inside a group group" do
      cases = [
        {:sibling_binding,
         [
           Syntax.branch(:pricing, [
             step_operation(:price_cart, EchoParamsAction, %{}, bind: :priced)
           ]),
           Syntax.branch(:inventory, [
             step_operation(:reserve_inventory, EchoParamsAction, Syntax.binding(:priced))
           ])
         ], "binding reference before it is bound",
         %{step: "reserve_inventory", binding: :priced}},
        {:sibling_after,
         [
           Syntax.branch(:pricing, [
             step_operation(:price_cart, EchoParamsAction, %{})
           ]),
           Syntax.branch(:inventory, [
             step_operation(:reserve_inventory, EchoParamsAction, %{}, after: :price_cart)
           ])
         ], "explicit dependency before it is bound",
         %{step: "reserve_inventory", dependency: "price_cart"}},
        {:sibling_result,
         [
           Syntax.branch(:pricing, [
             step_operation(:price_cart, EchoParamsAction, %{})
           ]),
           Syntax.branch(:inventory, [
             step_operation(:reserve_inventory, EchoParamsAction, %{
               priced: Syntax.result(:price_cart)
             })
           ])
         ], "result reference before it is bound",
         %{step: "reserve_inventory", dependency: "price_cart"}}
      ]

      for {_case_name, branches, expected_message, expected_details} <- cases do
        syntax =
          Syntax.new(name: "bad_group")
          |> Syntax.group(branches)
          |> Syntax.return(Syntax.result(:reserve_inventory))

        assert {:error, %InvalidInputError{message: message, details: details}} =
                 Lowerer.lower(syntax)

        assert message =~ expected_message

        for {key, value} <- expected_details do
          assert Map.fetch!(details, key) == value
        end
      end
    end

    test "rejects duplicate branch names in one group group" do
      syntax =
        Syntax.new(name: "duplicate_branch")
        |> Syntax.group([
          Syntax.branch(:pricing, []),
          Syntax.branch(:pricing, [])
        ])
        |> Syntax.return(Syntax.result(:price_cart))

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Lowerer.lower(syntax)

      assert message =~ "duplicate branch name"
      assert details.branch == :pricing
    end

    test "rejects malformed group branch structures" do
      cases = [
        {:branches_not_list, %{branches: :not_a_list}, "group branches must be a list",
         %{branches: :not_a_list}},
        {:invalid_branch_name, %{branches: [Syntax.branch("pricing", [])]},
         "branch name must be a non-nil atom", %{branch: "pricing"}},
        {:branch_operations_not_list,
         %{branches: [Syntax.operation(:branch, %{name: :pricing, operations: :not_a_list})]},
         "branch operations must be a list", %{branch: :pricing, operations: :not_a_list}},
        {:non_branch_operation, %{branches: [Syntax.operation(:step, %{name: "price_cart"})]},
         "group operations may contain only branch operations", %{kind: :step}},
        {:non_branch_value, %{branches: [:not_a_branch]},
         "group operations may contain only branch operations", %{branch: :not_a_branch}},
        {:non_step_branch_value, %{branches: [Syntax.branch(:pricing, [:not_a_step])]},
         "group branches may contain only step operations",
         %{branch: :pricing, operation: :not_a_step}}
      ]

      for {_case_name, attrs, expected_message, expected_details} <- cases do
        syntax =
          Syntax.new(name: "malformed_group")
          |> Syntax.add(Syntax.operation(:group, attrs))
          |> Syntax.return(Syntax.result(:price_cart))

        assert {:error, %InvalidInputError{message: message, details: details}} =
                 Lowerer.lower(syntax)

        assert message =~ expected_message

        for {key, value} <- expected_details do
          assert Map.fetch!(details, key) == value
        end
      end
    end

    test "rejects non-step operations inside group branches" do
      cases = [
        {:return, Syntax.operation(:return, %{expr: Syntax.result(:price_cart)})},
        {:group, Syntax.operation(:group, %{branches: []})}
      ]

      for {kind, operation} <- cases do
        syntax =
          Syntax.new(name: "bad_branch_operation")
          |> Syntax.group([
            Syntax.branch(:pricing, [operation])
          ])
          |> Syntax.return(Syntax.result(:price_cart))

        assert {:error, %InvalidInputError{message: message, details: details}} =
                 Lowerer.lower(syntax)

        assert message =~ "group branches may contain only step operations"
        assert details.branch == :pricing
        assert details.kind == kind
      end
    end

    test "rejects invalid explicit after step targets" do
      cases = [
        {:future_step,
         Syntax.new(name: "future_after")
         |> Syntax.step(:audit, EchoParamsAction, %{}, after: :load_quote)
         |> Syntax.step(:load_quote, EchoParamsAction, %{})
         |> Syntax.return(Syntax.result(:audit)), "explicit dependency before it is bound",
         %{step: "audit", dependency: "load_quote"}},
        {:unknown_step,
         Syntax.new(name: "unknown_after")
         |> Syntax.step(:audit, EchoParamsAction, %{}, after: :missing)
         |> Syntax.return(Syntax.result(:audit)), "unknown explicit dependency",
         %{step: "audit", dependency: "missing"}},
        {:self_step,
         Syntax.new(name: "self_after")
         |> Syntax.step(:audit, EchoParamsAction, %{}, after: :audit)
         |> Syntax.return(Syntax.result(:audit)),
         "explicit dependency cannot reference current step",
         %{step: "audit", dependency: "audit"}},
        {:future_binding,
         Syntax.new(name: "future_binding_after")
         |> Syntax.step(:audit, EchoParamsAction, %{}, after: Syntax.binding(:quote))
         |> Syntax.step(:load_quote, EchoParamsAction, %{}, bind: :quote)
         |> Syntax.return(Syntax.result(:audit)), "binding reference before it is bound",
         %{step: "audit", binding: :quote}},
        {:unknown_binding,
         Syntax.new(name: "unknown_binding_after")
         |> Syntax.step(:audit, EchoParamsAction, %{}, after: Syntax.binding(:missing))
         |> Syntax.return(Syntax.result(:audit)), "unknown binding handle",
         %{step: "audit", binding: :missing}},
        {:self_binding,
         Syntax.new(name: "self_binding_after")
         |> Syntax.step(:audit, EchoParamsAction, %{},
           bind: :audit_handle,
           after: Syntax.binding(:audit_handle)
         )
         |> Syntax.return(Syntax.result(:audit)),
         "explicit dependency cannot reference current binding",
         %{step: "audit", binding: :audit_handle}},
        {:expression_target,
         Syntax.new(name: "expression_after")
         |> Syntax.step(:load_quote, EchoParamsAction, %{})
         |> Syntax.step(:audit, EchoParamsAction, %{},
           after: Syntax.select(Syntax.input(:id), :x)
         )
         |> Syntax.return(Syntax.result(:audit)),
         "after targets must be step names or binding handles", %{step: "audit", type: :select}},
        {:ref_target,
         Syntax.new(name: "ref_after")
         |> Syntax.step(:load_quote, EchoParamsAction, %{})
         |> Syntax.step(:audit, EchoParamsAction, %{}, after: Ref.result(:load_quote))
         |> Syntax.return(Syntax.result(:audit)),
         "after targets must be step names or binding handles", %{step: "audit", type: :result}},
        {:map_target,
         Syntax.new(name: "map_after")
         |> Syntax.step(:load_quote, EchoParamsAction, %{})
         |> Syntax.step(:audit, EchoParamsAction, %{}, after: %{target: :load_quote})
         |> Syntax.return(Syntax.result(:audit)),
         "after targets must be step names or binding handles",
         %{step: "audit", target: %{target: :load_quote}}}
      ]

      for {_case_name, syntax, expected_message, expected_details} <- cases do
        assert {:error, %InvalidInputError{message: message, details: details}} =
                 Lowerer.lower(syntax)

        assert message =~ expected_message

        for {key, value} <- expected_details do
          assert Map.fetch!(details, key) == value
        end
      end
    end

    test "rejects an unknown binding handle" do
      syntax =
        Syntax.new(name: "unknown_binding")
        |> Syntax.step(:double, Multiply, Syntax.binding(:missing))
        |> Syntax.return(Syntax.result(:double))

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Lowerer.lower(syntax)

      assert message =~ "unknown binding handle"
      assert details.binding == :missing
      assert details.step == "double"
    end

    test "rejects a binding reference before the binding step has lowered" do
      syntax =
        Syntax.new(name: "before_binding")
        |> Syntax.step(:double, Multiply, Syntax.binding(:added))
        |> Syntax.step(:add_one, Add, %{value: Syntax.input(:value)}, bind: :added)
        |> Syntax.return(Syntax.result(:double))

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Lowerer.lower(syntax)

      assert message =~ "binding reference before it is bound"
      assert details.binding == :added
      assert details.step == "double"
    end

    test "rejects a binding used in its own step input" do
      syntax =
        Syntax.new(name: "self_binding")
        |> Syntax.step(:add_one, Add, Syntax.binding(:added), bind: :added)
        |> Syntax.return(Syntax.result(:add_one))

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Lowerer.lower(syntax)

      assert message =~ "binding cannot reference itself"
      assert details.binding == :added
      assert details.step == "add_one"
    end

    test "rejects a binding used in its own list input" do
      syntax =
        Syntax.new(name: "self_binding_list")
        |> Syntax.step(
          :add_one,
          Add,
          [Ref.input(:value), 1, Syntax.binding(:added)],
          bind: :added
        )
        |> Syntax.return(Syntax.result(:add_one))

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Lowerer.lower(syntax)

      assert message =~ "binding cannot reference itself"
      assert details.binding == :added
      assert details.step == "add_one"
    end

    test "rejects a binding used in its own select or map input" do
      cases = [
        Syntax.new(name: "self_binding_select")
        |> Syntax.step(:echo, EchoParamsAction, Syntax.select(Syntax.binding(:echoed), :id),
          bind: :echoed
        )
        |> Syntax.return(Syntax.result(:echo)),
        Syntax.new(name: "self_binding_map")
        |> Syntax.step(
          :echo,
          EchoParamsAction,
          %{id: Syntax.select(Syntax.binding(:echoed), :id)},
          bind: :echoed
        )
        |> Syntax.return(Syntax.result(:echo))
      ]

      for syntax <- cases do
        assert {:error, %InvalidInputError{message: message, details: details}} =
                 Lowerer.lower(syntax)

        assert message =~ "binding cannot reference itself"
        assert details.binding == :echoed
        assert details.step == "echo"
      end
    end

    test "rejects binding aliases that collide in the source namespace" do
      cases = [
        {:invalid_binding,
         Syntax.new(name: "invalid_binding")
         |> Syntax.step(:add_one, Add, %{}, bind: "added")
         |> Syntax.return(Syntax.result(:add_one)), "binding alias must be a non-nil atom",
         "added"},
        {:duplicate_binding,
         Syntax.new(name: "duplicate_binding")
         |> Syntax.step(:add_one, Add, %{}, bind: :added)
         |> Syntax.step(:double, Multiply, %{}, bind: :added)
         |> Syntax.return(Syntax.result(:double)), "duplicate binding alias", :added},
        {:reserved_binding,
         Syntax.new(name: "reserved_binding")
         |> Syntax.step(:add_one, Add, %{}, bind: :step)
         |> Syntax.return(Syntax.result(:add_one)), "reserved binding alias", :step},
        {:reserved_select_binding,
         Syntax.new(name: "reserved_select_binding")
         |> Syntax.step(:add_one, Add, %{}, bind: :select)
         |> Syntax.return(Syntax.result(:add_one)), "reserved binding alias", :select},
        {:reserved_context_binding,
         Syntax.new(name: "reserved_context_binding")
         |> Syntax.step(:add_one, Add, %{}, bind: :context)
         |> Syntax.return(Syntax.result(:add_one)), "reserved binding alias", :context},
        {:wildcard_binding,
         Syntax.new(name: "wildcard_binding")
         |> Syntax.step(:add_one, Add, %{}, bind: :_)
         |> Syntax.return(Syntax.result(:add_one)), "reserved binding alias", :_},
        {:step_name_collision,
         Syntax.new(name: "step_name_collision")
         |> Syntax.step(:add_one, Add, %{}, bind: :double)
         |> Syntax.step(:double, Multiply, %{})
         |> Syntax.return(Syntax.result(:double)), "binding alias conflicts with step name",
         :double}
      ]

      for {_case_name, syntax, expected_message, binding} <- cases do
        assert {:error, %InvalidInputError{message: message, details: details}} =
                 Lowerer.lower(syntax)

        assert message =~ expected_message
        assert details.binding == binding
      end
    end

    test "keeps invalid step names on canonical node validation" do
      syntax =
        Syntax.new(name: "invalid_step_name")
        |> Syntax.step(123, Add, %{}, bind: :added)
        |> Syntax.return(Syntax.result(:add_one))

      assert {:error, %InvalidInputError{message: message}} = Lowerer.lower(syntax)
      assert message =~ "node name must be a non-empty string or atom"
    end
  end

  describe "Map and Reduce lowering" do
    test "lowers names, bindings, deps, modes, local refs, and provenance" do
      syntax =
        Syntax.new(name: "fan_out_in")
        |> Syntax.step(:load, EchoParamsAction, %{items: Syntax.input(:items)}, bind: :loaded)
        |> Syntax.map(
          "mapped",
          Syntax.select(Syntax.binding(:loaded), :items),
          EchoParamsAction,
          %{
            item: Syntax.item(),
            value: Syntax.item(:value),
            index: Syntax.item_index(),
            item_id: Syntax.item_id()
          },
          on_error: :collect_errors,
          bind: :mapped_result,
          after: [Syntax.binding(:loaded)],
          provenance: %{line: 10}
        )
        |> Syntax.reduce(
          nil,
          Syntax.binding(:mapped_result),
          Syntax.value(%{total: 0}),
          EchoParamsAction,
          %{
            accumulator: Syntax.accumulator(),
            total: Syntax.accumulator(:total),
            item: Syntax.item(:output),
            index: Syntax.item_index(),
            item_id: Syntax.item_id()
          },
          bind: :summary,
          after: ["mapped", Syntax.binding(:mapped_result)],
          provenance: %{line: 20}
        )
        |> Syntax.return(Syntax.binding(:summary))

      assert {:ok, flow} = Lowerer.lower(syntax)
      assert [load, mapped, summary] = flow.nodes

      assert load.name == "load"
      assert %Jido.Flow.Map{} = mapped
      assert mapped.name == "mapped"
      assert mapped.collection == Ref.result("load", [:items])
      assert mapped.on_error == :collect_errors
      assert mapped.deps == ["load"]
      assert mapped.input.item == Ref.item()
      assert mapped.input.value == Ref.item(:value)
      assert mapped.input.index == Ref.item_index()
      assert mapped.input.item_id == Ref.item_id()
      assert mapped.provenance == %{binding: :mapped_result, line: 10}

      assert %Jido.Flow.Reduce{} = summary
      assert summary.name == "summary"
      assert summary.collection == Ref.result("mapped")
      assert summary.initial == Ref.value(%{total: 0})
      assert summary.deps == ["mapped"]
      assert summary.input.accumulator == Ref.accumulator()
      assert summary.input.total == Ref.accumulator(:total)
      assert summary.input.item == Ref.item(:output)
      assert summary.input.index == Ref.item_index()
      assert summary.input.item_id == Ref.item_id()
      assert summary.provenance == %{binding: :summary, line: 20}
      assert flow.return == Ref.result("summary")
    end

    test "preserves list order and trusted struct literals" do
      date = ~D[2026-08-21]

      syntax =
        Syntax.new(name: "literal_collections")
        |> Syntax.map(:mapped, [1, date, Syntax.input(:last)], EchoParamsAction, %{
          item: Syntax.item()
        })
        |> Syntax.reduce(
          :summary,
          Syntax.result(:mapped, :results),
          date,
          EchoParamsAction,
          %{acc: Syntax.accumulator(), item: Syntax.item()}
        )
        |> Syntax.return(Syntax.result(:summary))

      assert {:ok, flow} = Lowerer.lower(syntax)
      assert [mapped, summary] = flow.nodes
      assert mapped.collection == [Ref.value(1), Ref.value(date), Ref.input(:last)]
      assert summary.initial == Ref.value(date)

      direct =
        Flow.new!(
          name: "literal_collections",
          nodes: [
            Jido.Flow.Map.new!(
              name: :mapped,
              collection: [Ref.value(1), Ref.value(date), Ref.input(:last)],
              action: EchoParamsAction,
              input: %{item: Ref.item()}
            ),
            Jido.Flow.Reduce.new!(
              name: :summary,
              collection: Ref.result(:mapped, :results),
              initial: Ref.value(date),
              action: EchoParamsAction,
              input: %{acc: Ref.accumulator(), item: Ref.item()}
            )
          ],
          return: Ref.result(:summary)
        )

      assert Flow.to_map(flow) == Flow.to_map(direct)
    end

    test "rejects forward, missing, self-binding, and self-result references" do
      cases = [
        {Syntax.new(name: "forward")
         |> Syntax.map(:mapped, Syntax.binding(:later), Add, %{item: Syntax.item()})
         |> Syntax.step(:load_later, Add, %{}, bind: :later)
         |> Syntax.return(Syntax.result(:mapped)), "binding reference before it is bound",
         :later},
        {Syntax.new(name: "missing")
         |> Syntax.map(:mapped, Syntax.binding(:missing), Add, %{item: Syntax.item()})
         |> Syntax.return(Syntax.result(:mapped)), "unknown binding handle", :missing},
        {Syntax.new(name: "self_binding")
         |> Syntax.map(
           :mapped,
           Syntax.input(:items),
           Add,
           %{prior: Syntax.binding(:mapped_handle)},
           bind: :mapped_handle
         )
         |> Syntax.return(Syntax.result(:mapped)), "binding cannot reference itself",
         :mapped_handle},
        {Syntax.new(name: "self_result")
         |> Syntax.map(:mapped, Syntax.result(:mapped), Add, %{item: Syntax.item()})
         |> Syntax.return(Syntax.result(:mapped)), "result cannot reference current step",
         "mapped"}
      ]

      for {syntax, expected_message, expected_reference} <- cases do
        assert {:error, %InvalidInputError{message: message, details: details}} =
                 Lowerer.lower(syntax)

        assert message =~ expected_message
        assert details.step == "mapped"

        assert details[:binding] == expected_reference or
                 details[:dependency] == expected_reference
      end
    end

    test "rejects local refs outside their exact operation scopes with paths" do
      cases = [
        {Syntax.new(name: "map_collection")
         |> Syntax.map(:mapped, Syntax.item(), Add, %{item: Syntax.item()})
         |> Syntax.return(Syntax.result(:mapped)), [:collection], :item},
        {Syntax.new(name: "map_accumulator")
         |> Syntax.map(:mapped, Syntax.input(:items), Add, %{
           nested: %{bad: Syntax.accumulator()}
         })
         |> Syntax.return(Syntax.result(:mapped)), [:input, :nested, :bad], :accumulator},
        {Syntax.new(name: "reduce_collection")
         |> Syntax.reduce(:summary, Syntax.item(), Syntax.value(%{}), Add, %{
           item: Syntax.item(),
           acc: Syntax.accumulator()
         })
         |> Syntax.return(Syntax.result(:summary)), [:collection], :item},
        {Syntax.new(name: "reduce_initial")
         |> Syntax.reduce(:summary, Syntax.input(:items), Syntax.item_id(), Add, %{
           item: Syntax.item(),
           acc: Syntax.accumulator()
         })
         |> Syntax.return(Syntax.result(:summary)), [:initial], :item_id},
        {Syntax.new(name: "step_item")
         |> Syntax.step(:plain, Add, %{bad: Syntax.item()})
         |> Syntax.return(Syntax.result(:plain)), [:bad], :item},
        {Syntax.new(name: "return_item")
         |> Syntax.map(:mapped, Syntax.input(:items), Add, %{item: Syntax.item()})
         |> Syntax.return(%{result: Syntax.result(:mapped), bad: Syntax.item()}), [:bad], :item}
      ]

      for {syntax, path, type} <- cases do
        assert {:error, %InvalidInputError{details: details}} = Lowerer.lower(syntax)
        assert details.path == path
        assert details.type == type
      end
    end

    test "rejects unsupported and duplicate operation options" do
      unsupported =
        Syntax.new(name: "unsupported_option")
        |> Syntax.map(:mapped, Syntax.input(:items), Add, %{item: Syntax.item()}, timeout: 100)
        |> Syntax.return(Syntax.result(:mapped))

      duplicate =
        Syntax.new(name: "duplicate_option")
        |> Syntax.map(:mapped, Syntax.input(:items), Add, %{item: Syntax.item()},
          on_error: :fail_fast,
          on_error: :collect_errors
        )
        |> Syntax.return(Syntax.result(:mapped))

      unsupported_reduce =
        Syntax.new(name: "unsupported_reduce_option")
        |> Syntax.reduce(
          :summary,
          Syntax.input(:items),
          Syntax.value(%{}),
          Add,
          %{item: Syntax.item(), acc: Syntax.accumulator()},
          on_error: :collect_errors
        )
        |> Syntax.return(Syntax.result(:summary))

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Lowerer.lower(unsupported)

      assert message == "unsupported map option: :timeout"
      assert details.path == [:options, :timeout]

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Lowerer.lower(duplicate)

      assert message == "duplicate map option: :on_error"
      assert details.path == [:options, :on_error]

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Lowerer.lower(unsupported_reduce)

      assert message == "unsupported reduce option: :on_error"
      assert details.path == [:options, :on_error]
    end

    test "rejects invalid option containers and direct unsupported attributes" do
      invalid_options =
        Syntax.new(name: "invalid_options")
        |> Syntax.map(:mapped, Ref.input(:items), Add, %{item: Syntax.item()}, :not_keyword)
        |> Syntax.return(Syntax.result(:mapped))

      direct_attribute =
        Syntax.new(name: "direct_attribute")
        |> Syntax.add(
          Syntax.operation(:map, %{
            name: :mapped,
            collection: Ref.input(:items),
            action: Add,
            input: %{item: Syntax.item()},
            on_error: :fail_fast,
            timeout: 100
          })
        )
        |> Syntax.return(Syntax.result(:mapped))

      assert {:error,
              %InvalidInputError{
                message: "map options must be a keyword list",
                details: %{path: [:options], options: :not_keyword}
              }} = Lowerer.lower(invalid_options)

      assert {:error,
              %InvalidInputError{
                message: "unsupported map option: :timeout",
                details: %{path: [:options, :timeout]}
              }} = Lowerer.lower(direct_attribute)
    end

    test "keeps direct Refs scoped while validating missing and self names" do
      unnamed =
        Syntax.new(name: "unnamed")
        |> Syntax.map(nil, Ref.input(:items), Add, %{item: Syntax.item()})
        |> Syntax.return(Syntax.result(:mapped))

      self_result =
        Syntax.new(name: "direct_self_result")
        |> Syntax.map(:mapped, Ref.result(:mapped), Add, %{
          item: Syntax.item(),
          prior: Ref.input(:prior)
        })
        |> Syntax.return(Syntax.result(:mapped))

      assert {:error, %InvalidInputError{message: "map requires a name or a binding"}} =
               Lowerer.lower(unnamed)

      assert {:error,
              %InvalidInputError{
                message: "result cannot reference current step: \"mapped\"",
                details: %{dependency: "mapped"}
              }} = Lowerer.lower(self_result)
    end

    test "rejects bad modes, dynamic targets, and unsupported expressions at canonical paths" do
      cases = [
        {Syntax.new(name: "mode")
         |> Syntax.map(:mapped, Syntax.input(:items), Add, %{item: Syntax.item()},
           on_error: Syntax.value(:collect_errors)
         )
         |> Syntax.return(Syntax.result(:mapped)), "map on_error must be", [:on_error]},
        {Syntax.new(name: "dynamic_target")
         |> Syntax.map(:mapped, Syntax.input(:items), fn -> Add end, %{item: Syntax.item()})
         |> Syntax.return(Syntax.result(:mapped)), "map target must be a module atom", [:action]},
        {Syntax.new(name: "call")
         |> Syntax.map(:mapped, Syntax.input(:items), Add, %{
           item: %Syntax.Expr{type: :call}
         })
         |> Syntax.return(Syntax.result(:mapped)), "unsupported flow syntax expression", nil}
      ]

      for {syntax, expected_message, path} <- cases do
        assert {:error, %InvalidInputError{message: message, details: details}} =
                 Lowerer.lower(syntax)

        assert message =~ expected_message
        if path, do: assert(details.path == path)
      end
    end
  end

  defp step_operation(name, action, input, opts \\ []) do
    Syntax.new(name: "branch")
    |> Syntax.step(name, action, input, opts)
    |> Map.fetch!(:operations)
    |> List.first()
  end
end
