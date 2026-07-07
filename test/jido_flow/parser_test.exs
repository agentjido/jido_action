defmodule Jido.Flow.ParserTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Action.Error.InvalidInputError
  alias Jido.Flow
  alias Jido.Flow.Parser
  alias JidoTest.FlowFixtures

  describe "parse/2" do
    test "parses the math milestone string to the same canonical map as builder syntax" do
      assert {:ok, flow} =
               Flow.parse(FlowFixtures.math_source(),
                 name: "math_flow",
                 description: "Adds one and doubles the result"
               )

      assert Flow.to_map(flow) == FlowFixtures.math_canonical_map()
    end

    test "uses empty parser options by default" do
      assert {:error, %InvalidInputError{message: message}} =
               Parser.parse(FlowFixtures.math_source())

      assert message =~ "flow name must be a string"
    end

    test "keeps trusted parser profile as the default" do
      opts = [
        name: "math_flow",
        description: "Adds one and doubles the result",
        profile: :trusted
      ]

      assert {:ok, default_flow} =
               Flow.parse(FlowFixtures.math_source(), Keyword.delete(opts, :profile))

      assert {:ok, trusted_flow} = Flow.parse(FlowFixtures.math_source(), opts)
      assert Flow.to_map(trusted_flow) == Flow.to_map(default_flow)
    end

    test "rejects non-string source" do
      assert {:error, %InvalidInputError{message: message}} = Flow.parse(:not_source, name: "bad")
      assert message =~ "flow source must be a string"
    end

    test "rejects invalid Elixir syntax with source line metadata" do
      source = """
      flow do
        step :bad,
      end
      """

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Flow.parse(source, name: "bad")

      assert message =~ "invalid flow source"
      assert Keyword.fetch!(details.line, :line) == 3
    end

    test "rejects source without a single flow block" do
      assert {:error, %InvalidInputError{message: message, details: details}} =
               Flow.parse("input(:value)", name: "bad")

      assert message =~ "flow source must contain a single flow do block"
      assert details.form == "input(:value)"
    end

    test "rejects invalid parser options before lowering" do
      assert {:error, %InvalidInputError{message: message}} =
               Flow.parse(FlowFixtures.math_source(), :not_options)

      assert message =~ "flow parser options must be a map or keyword list"
    end

    test "rejects unsupported parser profiles before lowering" do
      assert {:error, %InvalidInputError{message: message, details: details}} =
               Flow.parse(FlowFixtures.math_source(), name: "bad", profile: :unsafe)

      assert message =~ "unsupported flow parser profile"
      assert details.profile == :unsafe
    end

    test "rejects invalid flow config supplied through parser options" do
      assert {:error, %InvalidInputError{message: message}} =
               Flow.parse(FlowFixtures.math_source(), name: " ")

      assert message =~ "Action name cannot be blank"
    end

    test "stored parser profile rejects source atoms that do not already exist" do
      atom_name = "__jido_flow_stored_new_atom_#{System.unique_integer([:positive])}"

      assert_raise ArgumentError, fn -> String.to_existing_atom(atom_name) end

      source = """
      flow do
        step :#{atom_name}, JidoTest.TestActions.Add, with: %{}
        return result(:#{atom_name})
      end
      """

      assert {:error, %InvalidInputError{message: message}} =
               Flow.parse(source, name: "bad", profile: :stored)

      assert message =~ "invalid flow source"
      assert message =~ "unsafe atom"
      assert_raise ArgumentError, fn -> String.to_existing_atom(atom_name) end
    end

    test "parses binding assignments, with input, and return by binding" do
      source = """
      flow do
        added = step :add_one, JidoTest.TestActions.Add, with: %{value: input(:value), amount: 1}
        doubled = step :double, JidoTest.TestActions.Multiply, with: added
        return doubled
      end
      """

      assert {:ok, flow} = Flow.parse(source, name: "binding_flow")
      assert [add_one, double] = Flow.to_map(flow).nodes
      assert add_one.input.value == %{type: :input, path: [:value]}
      assert add_one.input.amount == %{type: :value, value: 1}
      assert double.input == %{type: :result, node: :add_one, path: []}
      assert Flow.to_map(flow).return == %{type: :result, node: :double, path: []}
    end

    test "parses structurally valid trusted flows without checking action modules" do
      missing_action = unique_module("MissingTrustedAction")

      source = """
      flow do
        step :missing, #{inspect(missing_action)}, with: %{}
        return result(:missing)
      end
      """

      assert {:ok, flow} = Flow.parse(source, name: "unchecked_trusted_flow")
      assert [%{action: ^missing_action}] = Flow.to_map(flow).nodes

      assert {:error, %InvalidInputError{message: message, details: details}} = Flow.check(flow)
      assert message == "action module could not be loaded"
      assert details.node == :missing
      assert details.action == missing_action
    end

    test "parses step annotations as provenance only" do
      assert {:ok, flow} =
               Flow.parse(FlowFixtures.annotated_source(),
                 name: "annotated_flow",
                 description: "Annotates a step without changing semantics"
               )

      assert Flow.to_map(flow) == FlowFixtures.annotated_canonical_map()
      assert [%{provenance: provenance}] = Flow.to_map(flow, provenance: true).nodes
      assert provenance.label == "Add one"
      assert provenance.tags == ["math", "example"]
      assert provenance.note == "Visible only in provenance"
      assert is_integer(provenance.line)
      assert is_integer(provenance.column)
    end

    test "stored parser profile resolves registered action identifiers" do
      assert {:ok, flow} =
               Flow.parse(FlowFixtures.stored_annotated_source(),
                 name: "annotated_flow",
                 description: "Annotates a step without changing semantics",
                 profile: :stored,
                 actions: %{"add" => JidoTest.TestActions.Add}
               )

      assert Flow.to_map(flow) == FlowFixtures.annotated_canonical_map()
      assert {:ok, %{value: 4}} = Jido.Exec.run(flow, %{value: 3}, %{})

      assert [%{provenance: provenance}] = Flow.to_map(flow, provenance: true).nodes

      assert Map.take(provenance, [:label, :tags, :note]) == %{
               label: "Add one",
               tags: ["math", "example"],
               note: "Visible only in provenance"
             }
    end

    test "stored parser profile accepts keyword action registries" do
      source = """
      flow do
        step :add_one, :add, with: %{value: input(:value), amount: value(1)}
        return result(:add_one)
      end
      """

      assert {:ok, flow} =
               Flow.parse(source,
                 name: "annotated_flow",
                 description: "Annotates a step without changing semantics",
                 profile: :stored,
                 actions: [add: JidoTest.TestActions.Add]
               )

      assert Flow.to_map(flow) == FlowFixtures.annotated_canonical_map()
    end

    test "stored parser profile rejects unregistered action identifiers" do
      source = """
      flow do
        step :add_one, "missing", with: %{}
        return result(:add_one)
      end
      """

      assert {:error, %InvalidInputError{message: message}} =
               Flow.parse(source, name: "bad", profile: :stored, actions: %{})

      assert message =~ "unknown flow action identifier"
      assert message =~ "missing"
    end

    test "stored parser profile rejects direct action module aliases" do
      source = """
      flow do
        step :add_one, JidoTest.TestActions.Add, with: %{}
        return result(:add_one)
      end
      """

      assert {:error, %InvalidInputError{message: message}} =
               Flow.parse(source,
                 name: "bad",
                 profile: :stored,
                 actions: %{"add" => JidoTest.TestActions.Add}
               )

      assert message =~ "stored flow action modules must use registered identifiers"
    end

    test "stored parser profile rejects invalid action registries" do
      cases = [
        [:bad],
        %{123 => JidoTest.TestActions.Add},
        %{"add" => "not_module"},
        :bad
      ]

      for actions <- cases do
        assert {:error, %InvalidInputError{message: message, details: details}} =
                 Flow.parse(FlowFixtures.stored_annotated_source(),
                   name: "bad",
                   profile: :stored,
                   actions: actions
                 )

        assert message =~ "flow action registry must map string or atom identifiers to modules"
        assert details.actions == actions
      end
    end

    test "parses root list step input expressions" do
      source = """
      flow do
        step :echo, JidoTest.TestActions.EchoParamsAction, [input(:value), value(2), 3]
        return result(:echo)
      end
      """

      assert {:ok, flow} = Flow.parse(source, name: "list_input_flow")
      assert [echo] = Flow.to_map(flow).nodes

      assert echo.input == [
               %{type: :input, path: [:value]},
               %{type: :value, value: 2},
               %{type: :value, value: 3}
             ]
    end

    test "parses projection-only select expressions inside maps" do
      source = """
      flow do
        loaded =
          step :load_quote, JidoTest.TestActions.EchoParamsAction,
            with: %{
              quote: %{
                id: input(:quote_id),
                pricing: %{total: input([:items, 0, :price])}
              },
              tags: [input(:tag)]
            }

        audit =
          step :audit_quote, JidoTest.TestActions.EchoParamsAction,
            with: %{
              quote_id: select(loaded, [:quote, :id]),
              total: select(select(loaded, [:quote, :pricing]), :total),
              first_item_id: select(input(:items), [0, :id]),
              tenant_id: select(context(:tenant), :id),
              trace_id: context(:trace_id)
            }

        return select(audit, :total)
      end
      """

      assert {:ok, flow} = Flow.parse(source, name: "projection_flow")
      assert [_load_quote, audit_quote] = Flow.to_map(flow).nodes

      assert audit_quote.input == %{
               quote_id: %{type: :result, node: :load_quote, path: [:quote, :id]},
               total: %{
                 type: :result,
                 node: :load_quote,
                 path: [:quote, :pricing, :total]
               },
               first_item_id: %{type: :input, path: [:items, 0, :id]},
               tenant_id: %{type: :context, path: [:tenant, :id]},
               trace_id: %{type: :context, path: [:trace_id]}
             }

      assert Flow.to_map(flow).return == %{type: :result, node: :audit_quote, path: [:total]}
    end

    test "rejects shape expressions" do
      source = """
      flow do
        step :load_quote, JidoTest.TestActions.EchoParamsAction,
          with: shape(%{id: input(:quote_id)})

        return result(:load_quote)
      end
      """

      assert {:error, %InvalidInputError{message: message}} =
               Flow.parse(source, name: "bad_shape")

      assert message =~ "unsupported flow DSL expression"
    end

    test "parses explicit after targets in keyword step options" do
      source = """
      flow do
        loaded =
          step :load_quote, JidoTest.TestActions.EchoParamsAction,
            with: %{id: input(:quote_id)}

        step :independent, JidoTest.TestActions.EchoParamsAction,
          with: %{event: "side"}

        audit =
          step :audit_quote, JidoTest.TestActions.EchoParamsAction,
            with: %{event: "quoted"},
            after: [:load_quote, loaded]

        return audit
      end
      """

      assert {:ok, flow} = Flow.parse(source, name: "explicit_after_flow")
      assert [load_quote, independent, audit_quote] = Flow.to_map(flow).nodes

      assert load_quote.deps == []
      assert independent.deps == []
      assert audit_quote.deps == [:load_quote]
      assert audit_quote.input == %{event: %{type: :value, value: "quoted"}}
    end

    test "parses after before with in keyword step options" do
      source = """
      flow do
        loaded = step :load_quote, JidoTest.TestActions.EchoParamsAction, with: %{}

        audit =
          step :audit_quote, JidoTest.TestActions.EchoParamsAction,
            after: loaded,
            with: %{event: "quoted"}

        return audit
      end
      """

      assert {:ok, flow} = Flow.parse(source, name: "explicit_after_order_flow")
      assert [_load_quote, audit_quote] = Flow.to_map(flow).nodes
      assert audit_quote.deps == [:load_quote]
    end

    test "parses static parallel branch groups" do
      source = """
      flow do
        cart =
          step :load_cart, JidoTest.TestActions.EchoParamsAction,
            with: %{cart_id: input(:cart_id)}

        parallel do
          branch :alpha do
            priced =
              step :price_cart, JidoTest.TestActions.EchoParamsAction,
                with: cart
          end

          branch :beta do
            reserved =
              step :reserve_inventory, JidoTest.TestActions.EchoParamsAction,
                with: cart
          end
        end

        final =
          step :finalize, JidoTest.TestActions.EchoParamsAction,
            with: %{priced: priced, reserved: reserved}

        return final
      end
      """

      assert {:ok, flow} = Flow.parse(source, name: "static_parallel_flow")

      assert [load_cart, price_cart, reserve_inventory, finalize] = Flow.to_map(flow).nodes
      assert load_cart.deps == []
      assert price_cart.deps == [:load_cart]
      assert reserve_inventory.deps == [:load_cart]
      assert finalize.deps == [:price_cart, :reserve_inventory]

      refute inspect(Flow.to_map(flow)) =~ "alpha"
      refute inspect(Flow.to_map(flow)) =~ "beta"

      assert [
               _load_cart_provenance,
               %{provenance: %{branch: :alpha}},
               %{provenance: %{branch: :beta}},
               _finalize_provenance
             ] = Flow.to_map(flow, provenance: true).nodes
    end

    test "rejects arbitrary local function calls outside the Flow subset" do
      source = """
      flow do
        arbitrary(:value)
      end
      """

      assert {:error, %InvalidInputError{message: message}} = Flow.parse(source, name: "bad")
      assert message =~ "unsupported flow DSL operation"
    end

    test "rejects remote calls except action module aliases in the action position" do
      source = """
      flow do
        step :bad, String.upcase("x"), %{value: input(:value)}
        return result(:bad, :value)
      end
      """

      assert {:error, %InvalidInputError{message: message}} = Flow.parse(source, name: "bad")
      assert message =~ "unsupported flow DSL action module"
    end

    test "rejects unsafe or unsupported quoted forms" do
      cases = [
        {:remote_call_with, "step :bad, JidoTest.TestActions.Add, with: System.system_time()"},
        {:dot_projection, "step :bad, JidoTest.TestActions.Add, with: added.value"},
        {:capture, "step :bad, JidoTest.TestActions.Add, %{value: &String.upcase/1}"},
        {:sigil, "step :bad, JidoTest.TestActions.Add, %{value: ~s(value)}"},
        {:module_attribute, "step :bad, JidoTest.TestActions.Add, %{value: @value}"},
        {:comprehension, "step :bad, JidoTest.TestActions.Add, %{value: for(x <- [1], do: x)}"},
        {:import, "import String"},
        {:require, "require Integer"},
        {:nested_defmodule, "defmodule NestedFlowModule do\nend"}
      ]

      for {_kind, form} <- cases do
        source = "flow do\n#{form}\nreturn result(:bad)\nend"
        assert {:error, %InvalidInputError{message: message}} = Flow.parse(source, name: "bad")
        assert message =~ "unsupported flow DSL"
      end
    end

    test "rejects unsupported step options" do
      cases = [
        {:bind, "step :add_one, JidoTest.TestActions.Add, %{value: input(:value)}, bind: :added"},
        {:trailing_after, "step :add_one, JidoTest.TestActions.Add, %{}, after: :other"},
        {:after_without_with, "step :add_one, JidoTest.TestActions.Add, after: :other"},
        {:unknown_keyword, "step :add_one, JidoTest.TestActions.Add, with: %{}, unknown: true"},
        {:duplicate_with,
         "step :add_one, JidoTest.TestActions.Add, with: %{}, with: %{other: input(:value)}"},
        {:duplicate_after,
         """
         step :load, JidoTest.TestActions.Add, with: %{}
         step :add_one, JidoTest.TestActions.Add, with: %{}, after: :load, after: :load
         """},
        {:missing_input, "step :add_one, JidoTest.TestActions.Add"}
      ]

      for {_kind, form} <- cases do
        source = "flow do\n#{form}\nreturn result(:add_one)\nend"

        assert {:error, %InvalidInputError{message: message}} =
                 Flow.parse(source, name: "bad")

        assert message =~ "unsupported flow DSL step options"
      end
    end

    test "rejects computed step annotation values" do
      cases = [
        {:label, ~s|label: String.upcase("bad")|},
        {:tags, "tags: [System.system_time()]"},
        {:note, ~s|note: String.upcase("bad")|}
      ]

      for {_kind, option} <- cases do
        source = """
        flow do
          step :bad, JidoTest.TestActions.Add, with: %{}, #{option}
          return result(:bad)
        end
        """

        assert {:error, %InvalidInputError{message: message}} =
                 Flow.parse(source, name: "bad")

        assert message =~ "unsupported flow DSL"
      end
    end

    test "rejects invalid literal step annotation values" do
      cases = [
        {:label, "label: :bad"},
        {:note, "note: 123"},
        {:tags_keyword, "tags: [bad: :tag]"},
        {:tags_value, "tags: [1]"},
        {:tags_shape, "tags: :bad"}
      ]

      for {_kind, option} <- cases do
        source = """
        flow do
          step :bad, JidoTest.TestActions.Add, with: %{}, #{option}
          return result(:bad)
        end
        """

        assert {:error, %InvalidInputError{message: message}} =
                 Flow.parse(source, name: "bad")

        assert message =~ "unsupported flow DSL annotation"
      end
    end

    test "rejects unsupported branch group forms" do
      cases = [
        {:parallel_without_block, "parallel :bad", "unsupported flow DSL parallel"},
        {:branch_without_name,
         """
         parallel do
           branch do
             step :price_cart, JidoTest.TestActions.EchoParamsAction, with: %{}
           end
         end
         """, "unsupported flow DSL branch"},
        {:return_in_branch,
         """
         parallel do
           branch :alpha do
             return result(:price_cart)
           end
         end
         """, "parallel branches may contain only step operations"},
        {:nested_parallel,
         """
         parallel do
           branch :alpha do
             parallel do
               branch :nested do
                 step :price_cart, JidoTest.TestActions.EchoParamsAction, with: %{}
               end
             end
           end
         end
         """, "parallel branches may contain only step operations"},
        {:remote_call_in_branch,
         """
         parallel do
           branch :alpha do
             String.upcase("x")
           end
         end
         """, "unsupported flow DSL operation"}
      ]

      for {_kind, form, expected_message} <- cases do
        source = "flow do\n#{form}\nreturn result(:price_cart)\nend"

        assert {:error, %InvalidInputError{message: message}} =
                 Flow.parse(source, name: "bad")

        assert message =~ expected_message
      end
    end

    test "rejects unsupported explicit after targets" do
      cases = [
        {:select, "after: select(loaded, :id)"},
        {:shape, "after: shape(%{})"},
        {:remote_call, "after: System.system_time()"},
        {:dot_projection, "after: loaded.value"},
        {:keyword_list, "after: [loaded: :bad]"}
      ]

      for {_kind, option} <- cases do
        source = """
        flow do
          loaded = step :load_quote, JidoTest.TestActions.EchoParamsAction, with: %{}
          step :audit_quote, JidoTest.TestActions.EchoParamsAction, with: %{}, #{option}
          return result(:audit_quote)
        end
        """

        assert {:error, %InvalidInputError{message: message}} =
                 Flow.parse(source, name: "bad")

        assert message =~ "unsupported flow DSL after target"
      end
    end

    test "rejects keyword lists as input expressions" do
      source = """
      flow do
        step :echo, JidoTest.TestActions.EchoParamsAction, with: [value: input(:value)]
        return result(:echo)
      end
      """

      assert {:error, %InvalidInputError{message: message}} =
               Flow.parse(source, name: "bad")

      assert message =~ "unsupported flow DSL expression"
    end

    test "rejects invalid binding assignment forms with source line metadata" do
      cases = [
        {:right_side, "added = input(:value)"},
        {:tuple_pattern, "{added, other} = step :add_one, JidoTest.TestActions.Add, with: %{}"},
        {:list_pattern, "[added] = step :add_one, JidoTest.TestActions.Add, with: %{}"},
        {:pin, "^added = step :add_one, JidoTest.TestActions.Add, with: %{}"},
        {:nested, "added = doubled = step :add_one, JidoTest.TestActions.Add, with: %{}"},
        {:operator, "added + other"},
        {:local_call, "added()"},
        {:remote_call, "String.upcase(\"x\")"}
      ]

      for {_kind, form} <- cases do
        source = "flow do\n#{form}\nreturn result(:add_one)\nend"

        assert {:error, %InvalidInputError{message: message, details: details}} =
                 Flow.parse(source, name: "bad")

        assert message =~ "unsupported flow DSL"
        assert details.line == 2
      end
    end

    test "rejects unbound handles through lowerer validation" do
      source = """
      flow do
        step :add_one, JidoTest.TestActions.Add, with: missing
        return result(:add_one)
      end
      """

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Flow.parse(source, name: "bad")

      assert message =~ "unknown binding handle"
      assert details.binding == :missing
      assert details.step == :add_one
    end

    test "rejects wildcard binding assignments through lowerer validation" do
      source = """
      flow do
        _ = step :add_one, JidoTest.TestActions.Add, with: %{value: input(:value)}
        return result(:add_one)
      end
      """

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Flow.parse(source, name: "bad")

      assert message =~ "reserved binding alias"
      assert details.binding == :_
    end

    test "rejects local calls that look like variable alias references" do
      source = """
      flow do
        step :add_one, JidoTest.TestActions.Add, %{value: var(:missing, :value)}
        return result(:add_one, :value)
      end
      """

      assert {:error, %InvalidInputError{message: message}} = Flow.parse(source, name: "bad")

      assert message =~ "unsupported flow DSL expression"
    end

    test "rejects unsupported projection source forms" do
      cases = [
        {:computed_map_value,
         "step :bad, JidoTest.TestActions.EchoParamsAction, with: %{x: System.system_time()}",
         "unsupported flow DSL expression"},
        {:computed_path,
         """
         loaded = step :load_quote, JidoTest.TestActions.EchoParamsAction, with: %{}
         step :bad, JidoTest.TestActions.EchoParamsAction, with: %{x: select(loaded, System.system_time())}
         """, "unsupported flow DSL expression"},
        {:dot_projection,
         """
         loaded = step :load_quote, JidoTest.TestActions.EchoParamsAction, with: %{}
         step :bad, JidoTest.TestActions.EchoParamsAction, with: %{x: loaded.value}
         """, "unsupported flow DSL expression"},
        {:value_source,
         "step :bad, JidoTest.TestActions.EchoParamsAction, with: %{x: select(value(%{}), :id)}",
         "select source must resolve to an input, context, or result ref"}
      ]

      for {_kind, form, expected_message} <- cases do
        source = "flow do\n#{form}\nreturn result(:bad)\nend"

        assert {:error, %InvalidInputError{message: message}} =
                 Flow.parse(source, name: "bad")

        assert message =~ expected_message
      end
    end

    test "rejects unsupported context expressions" do
      cases = [
        {:missing_arg,
         "step :bad, JidoTest.TestActions.EchoParamsAction, with: %{trace_id: context()}"},
        {:extra_arg,
         "step :bad, JidoTest.TestActions.EchoParamsAction, with: %{trace_id: context(:a, :b)}"},
        {:computed_path,
         "step :bad, JidoTest.TestActions.EchoParamsAction, with: %{trace_id: context(System.system_time())}"},
        {:remote_call_path,
         "step :bad, JidoTest.TestActions.EchoParamsAction, with: %{trace_id: context(String.length(\"x\"))}"},
        {:keyword_path,
         "step :bad, JidoTest.TestActions.EchoParamsAction, with: %{trace_id: context([a: :b])}"}
      ]

      for {_kind, form} <- cases do
        source = "flow do\n#{form}\nreturn result(:bad)\nend"

        assert {:error, %InvalidInputError{message: message}} =
                 Flow.parse(source, name: "bad")

        assert message =~ "unsupported flow DSL expression"
      end
    end

    test "parses source as data and never executes it" do
      path =
        Path.join(
          System.tmp_dir!(),
          "jido_flow_parser_executed_#{System.unique_integer([:positive])}"
        )

      source = """
      flow do
        File.write!(#{inspect(path)}, "executed")
      end
      """

      assert {:error, %InvalidInputError{}} = Flow.parse(source, name: "bad")
      refute File.exists?(path)
    end

    test "includes source line metadata when available" do
      source = """
      flow do
        step :add_one, JidoTest.TestActions.Add, %{value: input(:value)}
        System.system_time()
      end
      """

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Flow.parse(source, name: "bad")

      assert message =~ "unsupported flow DSL operation"
      assert details.line == 3
    end
  end
end
