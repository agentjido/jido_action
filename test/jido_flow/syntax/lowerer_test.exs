defmodule Jido.Flow.Syntax.LowererTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Action.Error.InvalidInputError
  alias Jido.Flow
  alias Jido.Flow.Ref
  alias Jido.Flow.Syntax
  alias Jido.Flow.Syntax.Lowerer
  alias JidoTest.FlowFixtures
  alias JidoTest.TestActions.{Add, EchoParamsAction, Multiply}

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

      assert double.input.value == %{type: :result, node: :add_one, path: [:value]}
      assert double.input.amount == %{type: :value, value: 2}
      assert double.input.passthrough == %{type: :input, path: [:value]}
      assert double.input.literal == %{type: :value, value: 10}
    end

    test "lowers select and shape expressions to canonical refs and structures" do
      syntax =
        Syntax.new(name: "projection")
        |> Syntax.step(
          :load_quote,
          EchoParamsAction,
          Syntax.shape(%{
            quote: %{
              id: Syntax.input(:quote_id),
              pricing: %{total: Syntax.input([:items, 0, :price])}
            },
            tags: [Syntax.input(:tag)]
          }),
          bind: :loaded
        )
        |> Syntax.step(
          :audit_quote,
          EchoParamsAction,
          Syntax.shape(%{
            quote_id: Syntax.select(Syntax.binding(:loaded), [:quote, :id]),
            total:
              Syntax.select(
                Syntax.select(Syntax.binding(:loaded), [:quote, :pricing]),
                :total
              ),
            first_item_id: Syntax.select(Syntax.input(:items), [0, :id]),
            tag: Syntax.select(Syntax.binding(:loaded), [:tags, 0])
          }),
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
               quote_id: %{type: :result, node: :load_quote, path: [:quote, :id]},
               total: %{
                 type: :result,
                 node: :load_quote,
                 path: [:quote, :pricing, :total]
               },
               first_item_id: %{type: :input, path: [:items, 0, :id]},
               tag: %{type: :result, node: :load_quote, path: [:tags, 0]}
             }

      assert audit_quote.deps == [:load_quote]
      assert Flow.to_map(flow).return == %{type: :result, node: :audit_quote, path: [:total]}
      refute Flow.to_map(flow) |> inspect() |> String.contains?("select")
      refute Flow.to_map(flow) |> inspect() |> String.contains?("shape")
    end

    test "raw maps and equivalent shape expressions lower to the same canonical map" do
      raw =
        Syntax.new(name: "shape_equivalence")
        |> Syntax.step(:echo, EchoParamsAction, %{
          values: [Syntax.input(:value), Syntax.value(2)],
          metadata: %{source: "raw"}
        })
        |> Syntax.return(Syntax.result(:echo))

      shaped =
        Syntax.new(name: "shape_equivalence")
        |> Syntax.step(
          :echo,
          EchoParamsAction,
          Syntax.shape(%{
            values: [Syntax.input(:value), Syntax.value(2)],
            metadata: %{source: "raw"}
          })
        )
        |> Syntax.return(Syntax.result(:echo))

      assert {:ok, raw_flow} = Lowerer.lower(raw)
      assert {:ok, shaped_flow} = Lowerer.lower(shaped)
      assert Flow.to_map(raw_flow) == Flow.to_map(shaped_flow)
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

      assert message =~ "select source must resolve to an input or result ref"
      assert details.step == :echo
      assert details.type == :value
    end

    test "rejects select over shaped map or list sources" do
      cases = [
        {Syntax.shape(%{id: Syntax.input(:id)}), :map},
        {Syntax.shape([Syntax.input(:id)]), :list}
      ]

      for {source, type} <- cases do
        syntax =
          Syntax.new(name: "bad_shaped_select")
          |> Syntax.step(:echo, EchoParamsAction, %{value: Syntax.select(source, :id)})
          |> Syntax.return(Syntax.result(:echo))

        assert {:error, %InvalidInputError{message: message, details: details}} =
                 Lowerer.lower(syntax)

        assert message =~ "select source must resolve to an input or result ref"
        assert details.step == :echo
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
      assert details.step == :echo
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
        assert details.step == :echo
        assert details.path == path
      end
    end

    test "rejects shaped return values" do
      syntax =
        Syntax.new(name: "bad_shape_return")
        |> Syntax.step(:echo, EchoParamsAction, %{total: Syntax.input(:total)}, bind: :echoed)
        |> Syntax.return(Syntax.shape(%{total: Syntax.select(Syntax.binding(:echoed), :total)}))

      assert {:error, %InvalidInputError{message: message}} = Lowerer.lower(syntax)
      assert message =~ "return must resolve to a result ref"
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
      assert details.step == :double
      assert details.dependency == :missing
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
      assert double.input == %{type: :result, node: :add_one, path: []}
      assert double.deps == [:add_one]
      assert triple.input.value == %{type: :result, node: :add_one, path: []}
      assert semantic_map.return == %{type: :result, node: :double, path: []}

      provenance_map = Flow.to_map(flow, provenance: true)
      assert [add_one_provenance, double_provenance, _triple_provenance] = provenance_map.nodes
      assert add_one_provenance.provenance.binding == :added
      assert add_one_provenance.provenance.line == 10
      assert double_provenance.provenance.binding == :doubled
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
          Syntax.shape(%{event: "loaded"}),
          after: [:load_cart, Syntax.binding(:cart_handle), :load_cart]
        )
        |> Syntax.return(Syntax.result(:audit_cart))

      assert {:ok, flow} = Lowerer.lower(syntax)
      assert [load_cart, independent, audit_cart] = Flow.to_map(flow).nodes

      assert load_cart.deps == []
      assert independent.deps == []
      assert audit_cart.deps == [:load_cart]
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
          Syntax.shape(%{quote_id: Syntax.select(Syntax.binding(:quote), :id)}),
          after: Syntax.binding(:quote)
        )
        |> Syntax.return(Syntax.result(:audit_quote))

      assert {:ok, flow} = Lowerer.lower(syntax)
      assert [_load_quote, audit_quote] = Flow.to_map(flow).nodes

      assert audit_quote.deps == [:load_quote]

      assert audit_quote.input.quote_id == %{
               type: :result,
               node: :load_quote,
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

    test "rejects invalid explicit after step targets" do
      cases = [
        {:future_step,
         Syntax.new(name: "future_after")
         |> Syntax.step(:audit, EchoParamsAction, %{}, after: :load_quote)
         |> Syntax.step(:load_quote, EchoParamsAction, %{})
         |> Syntax.return(Syntax.result(:audit)), "explicit dependency before it is bound",
         %{step: :audit, dependency: :load_quote}},
        {:unknown_step,
         Syntax.new(name: "unknown_after")
         |> Syntax.step(:audit, EchoParamsAction, %{}, after: :missing)
         |> Syntax.return(Syntax.result(:audit)), "unknown explicit dependency",
         %{step: :audit, dependency: :missing}},
        {:self_step,
         Syntax.new(name: "self_after")
         |> Syntax.step(:audit, EchoParamsAction, %{}, after: :audit)
         |> Syntax.return(Syntax.result(:audit)),
         "explicit dependency cannot reference current step",
         %{step: :audit, dependency: :audit}},
        {:future_binding,
         Syntax.new(name: "future_binding_after")
         |> Syntax.step(:audit, EchoParamsAction, %{}, after: Syntax.binding(:quote))
         |> Syntax.step(:load_quote, EchoParamsAction, %{}, bind: :quote)
         |> Syntax.return(Syntax.result(:audit)), "binding reference before it is bound",
         %{step: :audit, binding: :quote}},
        {:unknown_binding,
         Syntax.new(name: "unknown_binding_after")
         |> Syntax.step(:audit, EchoParamsAction, %{}, after: Syntax.binding(:missing))
         |> Syntax.return(Syntax.result(:audit)), "unknown binding handle",
         %{step: :audit, binding: :missing}},
        {:self_binding,
         Syntax.new(name: "self_binding_after")
         |> Syntax.step(:audit, EchoParamsAction, %{},
           bind: :audit_handle,
           after: Syntax.binding(:audit_handle)
         )
         |> Syntax.return(Syntax.result(:audit)),
         "explicit dependency cannot reference current binding",
         %{step: :audit, binding: :audit_handle}},
        {:expression_target,
         Syntax.new(name: "expression_after")
         |> Syntax.step(:load_quote, EchoParamsAction, %{})
         |> Syntax.step(:audit, EchoParamsAction, %{},
           after: Syntax.select(Syntax.input(:id), :x)
         )
         |> Syntax.return(Syntax.result(:audit)),
         "after targets must be step names or binding handles", %{step: :audit, type: :select}},
        {:ref_target,
         Syntax.new(name: "ref_after")
         |> Syntax.step(:load_quote, EchoParamsAction, %{})
         |> Syntax.step(:audit, EchoParamsAction, %{}, after: Ref.result(:load_quote))
         |> Syntax.return(Syntax.result(:audit)),
         "after targets must be step names or binding handles", %{step: :audit, type: :result}},
        {:map_target,
         Syntax.new(name: "map_after")
         |> Syntax.step(:load_quote, EchoParamsAction, %{})
         |> Syntax.step(:audit, EchoParamsAction, %{}, after: %{target: :load_quote})
         |> Syntax.return(Syntax.result(:audit)),
         "after targets must be step names or binding handles",
         %{step: :audit, target: %{target: :load_quote}}}
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
      assert details.step == :double
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
      assert details.step == :double
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
      assert details.step == :add_one
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
      assert details.step == :add_one
    end

    test "rejects a binding used in its own select or shape input" do
      cases = [
        Syntax.new(name: "self_binding_select")
        |> Syntax.step(:echo, EchoParamsAction, Syntax.select(Syntax.binding(:echoed), :id),
          bind: :echoed
        )
        |> Syntax.return(Syntax.result(:echo)),
        Syntax.new(name: "self_binding_shape")
        |> Syntax.step(
          :echo,
          EchoParamsAction,
          Syntax.shape(%{id: Syntax.select(Syntax.binding(:echoed), :id)}),
          bind: :echoed
        )
        |> Syntax.return(Syntax.result(:echo))
      ]

      for syntax <- cases do
        assert {:error, %InvalidInputError{message: message, details: details}} =
                 Lowerer.lower(syntax)

        assert message =~ "binding cannot reference itself"
        assert details.binding == :echoed
        assert details.step == :echo
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
        {:reserved_shape_binding,
         Syntax.new(name: "reserved_shape_binding")
         |> Syntax.step(:add_one, Add, %{}, bind: :shape)
         |> Syntax.return(Syntax.result(:add_one)), "reserved binding alias", :shape},
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
        |> Syntax.step(nil, Add, %{}, bind: :added)
        |> Syntax.return(Syntax.result(:add_one))

      assert {:error, %InvalidInputError{message: message}} = Lowerer.lower(syntax)
      assert message =~ "node name must be a non-nil atom"
    end
  end
end
