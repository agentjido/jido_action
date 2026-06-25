defmodule Jido.Flow.ParserTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Action.Error.InvalidInputError
  alias Jido.Flow
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

    test "rejects variable alias references for now" do
      source = """
      flow do
        step :add_one, JidoTest.TestActions.Add, %{value: var(:missing, :value)}
        return result(:add_one, :value)
      end
      """

      assert {:error, %InvalidInputError{message: message}} = Flow.parse(source, name: "bad")

      assert message =~ "unsupported flow DSL expression"
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

    test "provenance can be inspected without changing the semantic map" do
      assert {:ok, flow} =
               Flow.parse(FlowFixtures.math_source(),
                 name: "math_flow",
                 description: "Adds one and doubles the result"
               )

      semantic = Flow.to_map(flow)
      provenance = Flow.to_map(flow, provenance: true)

      assert semantic == FlowFixtures.math_canonical_map()
      assert Map.has_key?(provenance, :provenance)
      refute Map.has_key?(semantic, :provenance)
    end
  end
end
