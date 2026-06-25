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

    test "rejects invalid flow config supplied through parser options" do
      assert {:error, %InvalidInputError{message: message}} =
               Flow.parse(FlowFixtures.math_source(), name: " ")

      assert message =~ "Action name cannot be blank"
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

    test "parses projection-only select and shape expressions" do
      source = """
      flow do
        loaded =
          step :load_quote, JidoTest.TestActions.EchoParamsAction,
            with: shape(%{
              quote: %{
                id: input(:quote_id),
                pricing: %{total: input([:items, 0, :price])}
              },
              tags: [input(:tag)]
            })

        audit =
          step :audit_quote, JidoTest.TestActions.EchoParamsAction,
            with: shape(%{
              quote_id: select(loaded, [:quote, :id]),
              total: select(select(loaded, [:quote, :pricing]), :total),
              first_item_id: select(input(:items), [0, :id])
            })

        return select(audit, :total)
      end
      """

      assert {:ok, flow} = Flow.parse(source, name: "projection_shape_flow")
      assert [_load_quote, audit_quote] = Flow.to_map(flow).nodes

      assert audit_quote.input == %{
               quote_id: %{type: :result, node: :load_quote, path: [:quote, :id]},
               total: %{
                 type: :result,
                 node: :load_quote,
                 path: [:quote, :pricing, :total]
               },
               first_item_id: %{type: :input, path: [:items, 0, :id]}
             }

      assert Flow.to_map(flow).return == %{type: :result, node: :audit_quote, path: [:total]}
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
        {:unknown, "step :add_one, JidoTest.TestActions.Add, with: %{}, after: :other"},
        {:missing_input, "step :add_one, JidoTest.TestActions.Add"}
      ]

      for {_kind, form} <- cases do
        source = "flow do\n#{form}\nreturn result(:add_one)\nend"

        assert {:error, %InvalidInputError{message: message}} =
                 Flow.parse(source, name: "bad")

        assert message =~ "unsupported flow DSL step options"
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

    test "rejects unsupported projection and shape source forms" do
      cases = [
        {:computed_shape,
         "step :bad, JidoTest.TestActions.EchoParamsAction, with: shape(%{x: System.system_time()})",
         "unsupported flow DSL expression"},
        {:computed_path,
         """
         loaded = step :load_quote, JidoTest.TestActions.EchoParamsAction, with: %{}
         step :bad, JidoTest.TestActions.EchoParamsAction, with: %{x: select(loaded, System.system_time())}
         """, "unsupported flow DSL expression"},
        {:dot_projection,
         """
         loaded = step :load_quote, JidoTest.TestActions.EchoParamsAction, with: %{}
         step :bad, JidoTest.TestActions.EchoParamsAction, with: shape(%{x: loaded.value})
         """, "unsupported flow DSL expression"},
        {:value_source,
         "step :bad, JidoTest.TestActions.EchoParamsAction, with: %{x: select(value(%{}), :id)}",
         "select source must resolve to an input or result ref"}
      ]

      for {_kind, form, expected_message} <- cases do
        source = "flow do\n#{form}\nreturn result(:bad)\nend"

        assert {:error, %InvalidInputError{message: message}} =
                 Flow.parse(source, name: "bad")

        assert message =~ expected_message
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
