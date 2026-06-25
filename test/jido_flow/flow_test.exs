defmodule Jido.FlowTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Action.Error.InvalidInputError
  alias Jido.Flow
  alias Jido.Flow.{Node, Ref, Syntax}
  alias JidoTest.TestActions.{Add, MissingRun}

  describe "new/1" do
    test "creates a minimal valid flow and emits a deterministic canonical map" do
      node =
        Node.new!(
          name: :add_one,
          action: Add,
          input: %{
            value: Ref.input(:value),
            amount: Ref.value(1)
          }
        )

      assert {:ok, flow} =
               Flow.new(
                 name: "math",
                 description: "Adds one",
                 nodes: [node],
                 return: Ref.result(:add_one, :value)
               )

      assert flow.__struct__ == Flow
      assert flow.name == "math"
      assert flow.description == "Adds one"

      assert Flow.to_map(flow) == %{
               type: :flow,
               name: "math",
               description: "Adds one",
               schema: [],
               output_schema: [],
               nodes: [
                 %{
                   name: :add_one,
                   action: Add,
                   input: %{
                     value: %{type: :input, path: [:value]},
                     amount: %{type: :value, value: 1}
                   },
                   deps: []
                 }
               ],
               return: %{type: :result, node: :add_one, path: [:value]}
             }
    end

    test "rejects duplicate node names with the duplicated name" do
      attrs = [
        name: "bad",
        nodes: [
          [name: :add_one, action: Add],
          [name: :add_one, action: Add]
        ],
        return: Ref.result(:add_one)
      ]

      assert {:error, %InvalidInputError{message: message, details: details}} = Flow.new(attrs)
      assert message =~ "duplicate step name"
      assert details.name == :add_one
    end

    test "rejects a return ref that does not point to a known node" do
      attrs = [
        name: "bad",
        nodes: [[name: :add_one, action: Add]],
        return: Ref.result(:missing, :value)
      ]

      assert {:error, %InvalidInputError{message: message, details: details}} = Flow.new(attrs)
      assert message =~ "return ref points to an unknown step"
      assert details.node == :missing
    end

    test "rejects a node whose action module does not expose the action contract" do
      attrs = [
        name: "bad",
        nodes: [[name: :broken, action: MissingRun]],
        return: Ref.result(:broken)
      ]

      assert {:error, %InvalidInputError{message: message, details: details}} = Flow.new(attrs)
      assert message =~ "module is not a valid Jido action"
      assert details.node == :broken
      assert details.action == MissingRun
      assert details.reason == "missing run/2"
    end

    test "revalidates prebuilt node structs instead of trusting canonical shape" do
      node = %Node{
        name: :add_one,
        action: Add,
        input: %{value: Syntax.input(:value), amount: Ref.value(1)},
        deps: [],
        provenance: %{}
      }

      attrs = [
        name: "bad",
        nodes: [node],
        return: Ref.result(:add_one, :value)
      ]

      assert {:error, %InvalidInputError{message: message, details: details}} = Flow.new(attrs)
      assert message =~ "node input contains unsupported expression"
      assert details.path == [:value]
      assert details.expression == Syntax.Expr
    end

    test "keeps provenance out of the canonical semantic map unless requested" do
      node =
        Node.new!(
          name: :add_one,
          action: Add,
          input: %{value: Ref.input(:value)},
          provenance: %{line: 12, binding: :friendly_name}
        )

      flow =
        Flow.new!(
          name: "math",
          nodes: [node],
          return: Ref.result(:add_one),
          provenance: %{source: :builder, binding_table: %{friendly_name: :add_one}}
        )

      semantic_map = Flow.to_map(flow)
      refute Map.has_key?(semantic_map, :provenance)
      refute semantic_map |> inspect() |> String.contains?("friendly_name")

      provenance_map = Flow.to_map(flow, provenance: true)
      assert provenance_map.provenance.source == :builder
      assert [%{provenance: node_provenance}] = provenance_map.nodes
      assert node_provenance.line == 12
      assert node_provenance.binding == :friendly_name
    end
  end

  describe "new!/1" do
    test "raises validation errors on invalid flow configuration" do
      assert_raise InvalidInputError, ~r/return ref is required/, fn ->
        Flow.new!(name: "bad", nodes: [[name: :add_one, action: Add]])
      end
    end
  end
end
