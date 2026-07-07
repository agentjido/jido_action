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

    test "checks nodes whose action modules do not expose the action contract" do
      attrs = [
        name: "bad",
        nodes: [[name: :broken, action: MissingRun]],
        return: Ref.result(:broken)
      ]

      assert {:ok, flow} = Flow.new(attrs)

      assert {:error, %InvalidInputError{message: message, details: details}} = Flow.check(flow)
      assert message =~ "module is not a valid Jido action"
      assert details.node == :broken
      assert details.action == MissingRun
      assert details.reason == "missing run/2"
    end

    test "accepts structurally valid flows with unloaded action modules" do
      missing_action = unique_module("MissingAction")

      attrs = [
        name: "unchecked",
        nodes: [[name: :missing, action: missing_action]],
        return: Ref.result(:missing)
      ]

      assert {:ok, flow} = Flow.new(attrs)

      assert {:error, %InvalidInputError{message: message, details: details}} = Flow.check(flow)
      assert message == "action module could not be loaded"
      assert details.node == :missing
      assert details.action == missing_action
      assert details.reason == :nofile
    end

    test "rejects cyclic dependency graphs" do
      attrs = [
        name: "cycle",
        nodes: [
          [
            name: :first,
            action: Add,
            input: %{value: Ref.input(:value)},
            deps: [:second]
          ],
          [
            name: :second,
            action: Add,
            input: %{value: Ref.input(:value)},
            deps: [:first]
          ]
        ],
        return: Ref.result(:second)
      ]

      assert {:error, %InvalidInputError{message: message, details: details}} = Flow.new(attrs)
      assert message =~ "flow dependency graph contains a cycle"
      assert Enum.sort(details.nodes) == [:first, :second]
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

    test "revalidates existing flow structs" do
      flow =
        Flow.new!(
          name: "prebuilt",
          nodes: [add_node()],
          return: Ref.result(:add_one, :value)
        )

      assert {:ok, ^flow} = Flow.new(flow)
    end

    test "accepts nil schema, output schema, and provenance defaults" do
      assert {:ok, flow} =
               Flow.new(
                 name: "nil_defaults",
                 schema: nil,
                 output_schema: nil,
                 nodes: [add_node()],
                 return: Ref.result(:add_one, :value),
                 provenance: nil
               )

      assert flow.schema == []
      assert flow.output_schema == []
      assert flow.provenance == %{}
    end

    test "accepts context refs in node inputs without adding normalized deps" do
      assert {:ok, flow} =
               Flow.new(
                 name: "context",
                 nodes: [
                   [
                     name: :audit,
                     action: Add,
                     input: %{
                       value: Ref.context(:trace_id),
                       amount: 1
                     }
                   ]
                 ],
                 return: Ref.result(:audit, :value)
               )

      assert [node] = flow.nodes
      assert node.deps == []

      assert Flow.to_map(flow).nodes == [
               %{
                 name: :audit,
                 action: Add,
                 input: %{
                   value: %{type: :context, path: [:trace_id]},
                   amount: %{type: :value, value: 1}
                 },
                 deps: []
               }
             ]
    end

    test "rejects invalid top-level configuration shapes" do
      assert {:error, %InvalidInputError{message: "flow configuration must be a map"}} =
               Flow.new(:not_attrs)

      assert {:error, %InvalidInputError{message: "flow name must be a string"}} =
               Flow.new(name: :bad)

      assert {:error, %InvalidInputError{message: "flow description must be a string"}} =
               Flow.new(name: "bad", description: 123)

      assert {:error, %InvalidInputError{message: "schema must be a Zoi schema"}} =
               Flow.new(name: "bad", schema: :not_schema)

      assert {:error, %InvalidInputError{message: "flow nodes must be a list"}} =
               Flow.new(name: "bad", nodes: :not_nodes)

      assert {:error, %InvalidInputError{message: "return must be a result ref"}} =
               Flow.new(name: "bad", nodes: [add_node()], return: Ref.value(:not_a_result))

      assert {:error, %InvalidInputError{message: "return must be a result ref"}} =
               Flow.new(name: "bad", nodes: [add_node()], return: Ref.context(:trace_id))

      assert {:error, %InvalidInputError{message: "flow provenance must be a map"}} =
               Flow.new(
                 name: "bad",
                 nodes: [add_node()],
                 return: Ref.result(:add_one, :value),
                 provenance: :not_provenance
               )
    end

    test "rejects non-map DSL configuration" do
      assert {:error, %InvalidInputError{message: "flow configuration must be a map"}} =
               Flow.__validate_config__(:not_attrs)
    end

    test "rejects node result refs pointing at unknown steps" do
      attrs = [
        name: "bad",
        nodes: [
          [
            name: :add_one,
            action: Add,
            input: %{value: Ref.result(:missing, :value)}
          ]
        ],
        return: Ref.result(:add_one, :value)
      ]

      assert {:error, %InvalidInputError{message: message, details: details}} = Flow.new(attrs)
      assert message =~ "node input points to an unknown step"
      assert details.node == :add_one
      assert details.dependency == :missing
    end

    test "rejects explicit node deps pointing at unknown steps" do
      attrs = [
        name: "bad",
        nodes: [
          [
            name: :audit,
            action: Add,
            input: %{value: Ref.input(:value)},
            deps: [:missing]
          ]
        ],
        return: Ref.result(:audit, :value)
      ]

      assert {:error, %InvalidInputError{message: message, details: details}} = Flow.new(attrs)
      assert message =~ "node input points to an unknown step"
      assert details.node == :audit
      assert details.dependency == :missing
    end
  end

  describe "new!/1" do
    test "raises validation errors on invalid flow configuration" do
      assert_raise InvalidInputError, ~r/return ref is required/, fn ->
        Flow.new!(name: "bad", nodes: [[name: :add_one, action: Add]])
      end
    end
  end

  defp add_node do
    Node.new!(
      name: :add_one,
      action: Add,
      input: %{value: Ref.input(:value), amount: Ref.value(1)}
    )
  end
end
