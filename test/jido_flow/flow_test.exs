defmodule Jido.FlowTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Action.Error.InvalidInputError
  alias Jido.Flow
  alias Jido.Flow.{Choice, Condition, Node, Ref, Syntax}
  alias JidoTest.TestActions.{Add, EchoParamsAction, MissingRun, Multiply}

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
               version: 1,
               name: "math",
               description: "Adds one",
               schema: [],
               output_schema: [],
               nodes: [
                 %{
                   name: "add_one",
                   action: Add,
                   input: %{
                     value: %{type: :input, path: [:value]},
                     amount: %{type: :value, value: 1}
                   },
                   deps: []
                 }
               ],
               return: %{type: :result, node: "add_one", path: [:value]}
             }
    end

    test "rejects unknown Flow attributes" do
      assert {:error, %InvalidInputError{message: message, details: details}} =
               Flow.new(
                 name: "unknown_attribute",
                 nodes: [add_node()],
                 return: Ref.result(:add_one),
                 output_shema: []
               )

      assert message == "unknown Flow configuration key: :output_shema"
      assert details.key == :output_shema
    end

    test "requires map-shaped input and output schemas" do
      for field <- [:schema, :output_schema] do
        attrs = %{
          name: "scalar_schema",
          nodes: [add_node()],
          return: Ref.result(:add_one)
        }

        assert {:error, %InvalidInputError{message: message, details: details}} =
                 attrs |> Map.put(field, Zoi.integer()) |> Flow.new()

        assert message == "#{field} must accept map-shaped action data"
        assert details.field == Atom.to_string(field)
      end
    end

    test "rejects runtime-only schemas and semantic values" do
      anonymous_schema =
        Zoi.object(%{value: Zoi.integer() |> Zoi.refine(fn _value -> :ok end)})

      assert {:error, %InvalidInputError{message: schema_message}} =
               Flow.new(
                 name: "dynamic_schema",
                 schema: anonymous_schema,
                 nodes: [add_node()],
                 return: Ref.result(:add_one)
               )

      assert schema_message =~ "schema must be static module data"
      assert schema_message =~ "anonymous functions are not supported"

      node =
        Node.new!(
          name: :echo,
          action: EchoParamsAction,
          input: %{value: Ref.value(self())}
        )

      assert {:error, %InvalidInputError{message: value_message}} =
               Flow.new(name: "runtime_value", nodes: [node], return: Ref.result(:echo))

      assert value_message =~ "Flow semantic data must be static module data"
      assert value_message =~ "runtime process values are not supported"
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
      assert details.name == "add_one"
    end

    test "rejects a return ref that does not point to a known node" do
      attrs = [
        name: "bad",
        nodes: [[name: :add_one, action: Add]],
        return: Ref.result(:missing, :value)
      ]

      assert {:error, %InvalidInputError{message: message, details: details}} = Flow.new(attrs)
      assert message =~ "return ref points to an unknown step"
      assert details.node == "missing"
    end

    test "accepts shaped return expressions with at least one result ref" do
      add_one =
        Node.new!(
          name: :add_one,
          action: Add,
          input: %{value: Ref.input(:value), amount: Ref.value(1)}
        )

      double =
        Node.new!(
          name: :double,
          action: Multiply,
          input: %{value: Ref.result(:add_one, :value), amount: Ref.value(2)}
        )

      assert {:ok, flow} =
               Flow.new(
                 name: "shaped_return",
                 nodes: [add_one, double],
                 return: %{
                   sum: Ref.result(:add_one, :value),
                   product: Ref.result(:double, :value),
                   original: Ref.input(:value),
                   literal: "ok",
                   nested: [Ref.result(:double, :value)]
                 }
               )

      assert Flow.to_map(flow).return == %{
               sum: %{type: :result, node: "add_one", path: [:value]},
               product: %{type: :result, node: "double", path: [:value]},
               original: %{type: :input, path: [:value]},
               literal: %{type: :value, value: "ok"},
               nested: [%{type: :result, node: "double", path: [:value]}]
             }
    end

    test "rejects shaped return expressions without a result ref" do
      attrs = [
        name: "bad",
        nodes: [[name: :add_one, action: Add]],
        return: %{original: Ref.input(:value), constant: Ref.value(1)}
      ]

      assert {:error, %InvalidInputError{message: message}} = Flow.new(attrs)
      assert message =~ "return must reference at least one step result"
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
      assert details.node == "broken"
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
      assert details.node == "missing"
      assert details.action == missing_action
      assert details.reason == :nofile
    end

    test "keeps Choice structural validation inert and checks targets in authored order" do
      choice =
        Choice.new!(
          name: :route,
          options: [
            [name: :first, condition: Condition.eq(1, 1), action: Add],
            [name: :second, condition: Condition.eq(1, 1), action: MissingRun]
          ],
          fallback: [action: MissingRun]
        )

      assert {:ok, flow} =
               Flow.new(name: "unchecked_choice", nodes: [choice], return: Ref.result(:route))

      assert {:ok, ^flow} = Flow.validate(flow)

      assert {:error, %InvalidInputError{message: message, details: details}} = Flow.check(flow)
      assert message =~ "module is not a valid Jido action"
      assert details.choice == "route"
      assert details.option == "second"
      assert details.target == MissingRun
    end

    test "normalizes Choice keyword attributes in the nodes list" do
      assert {:ok, flow} =
               Flow.new(
                 name: "choice_attrs",
                 nodes: [
                   [
                     name: :route,
                     options: [
                       [name: :priority, condition: Condition.eq(1, 1), action: Add]
                     ],
                     fallback: [action: Add]
                   ]
                 ],
                 return: Ref.result(:route)
               )

      assert [%Choice{name: "route"}] = flow.nodes
    end

    test "applies existing unknown reference and cycle checks to Choice dependencies" do
      unknown_choice =
        Choice.new!(
          name: :route,
          options: [
            [
              name: :priority,
              condition: Condition.eq(Ref.result(:missing, :kind), :priority),
              action: Add
            ]
          ],
          fallback: [action: Add]
        )

      assert {:error, %InvalidInputError{message: unknown_message, details: unknown_details}} =
               Flow.new(
                 name: "unknown_choice",
                 nodes: [unknown_choice],
                 return: Ref.result(:route)
               )

      assert unknown_message =~ "node input points to an unknown step"
      assert unknown_details.node == "route"
      assert unknown_details.dependency == "missing"

      cyclic_choice =
        Choice.new!(
          name: :route,
          options: [
            [
              name: :priority,
              condition: Condition.eq(Ref.result(:next, :value), 1),
              action: Add
            ]
          ],
          fallback: [action: Add]
        )

      next = Node.new!(name: :next, action: Add, deps: [:route])

      assert {:error, %InvalidInputError{message: cycle_message, details: cycle_details}} =
               Flow.new(
                 name: "cyclic_choice",
                 nodes: [cyclic_choice, next],
                 return: Ref.result(:route)
               )

      assert cycle_message =~ "flow dependency graph contains a cycle"
      assert Enum.sort(cycle_details.nodes) == ["next", "route"]
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
      assert Enum.sort(details.nodes) == ["first", "second"]
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

    test "canonical maps ignore source order between independent nodes" do
      load =
        Node.new!(
          name: :load,
          action: Add,
          input: %{value: Ref.input(:value), amount: Ref.value(1)}
        )

      finish =
        Node.new!(
          name: :finish,
          action: Add,
          input: %{value: Ref.result(:load, :value), amount: Ref.value(1)}
        )

      audit =
        Node.new!(
          name: :audit,
          action: Add,
          input: %{value: Ref.input(:value), amount: Ref.value(0)}
        )

      first =
        Flow.new!(name: "equivalent", nodes: [load, finish, audit], return: Ref.result(:finish))

      second =
        Flow.new!(name: "equivalent", nodes: [audit, load, finish], return: Ref.result(:finish))

      assert Flow.to_map(first) == Flow.to_map(second)
      assert Enum.map(Flow.to_map(first).nodes, & &1.name) == ["audit", "load", "finish"]
    end

    test "canonical maps order independent roots by node name" do
      flow =
        Flow.new!(
          name: "roots",
          nodes: [
            Node.new!(name: :c, action: Add, input: %{value: Ref.input(:value)}),
            Node.new!(name: :a, action: Add, input: %{value: Ref.input(:value)}),
            Node.new!(name: :b, action: Add, input: %{value: Ref.input(:value)})
          ],
          return: Ref.result(:a)
        )

      assert Enum.map(Flow.to_map(flow).nodes, & &1.name) == ["a", "b", "c"]
      assert Enum.map(flow.nodes, & &1.name) == ["c", "a", "b"]
    end

    test "canonical maps emit dependency order regardless of authoring order" do
      flow =
        Flow.new!(
          name: "diamond",
          nodes: [
            Node.new!(
              name: :d,
              action: Add,
              input: %{value: Ref.result(:b, :value), amount: Ref.result(:c, :value)}
            ),
            Node.new!(
              name: :c,
              action: Add,
              input: %{value: Ref.result(:a, :value), amount: Ref.value(1)}
            ),
            Node.new!(
              name: :b,
              action: Add,
              input: %{value: Ref.result(:a, :value), amount: Ref.value(1)}
            ),
            Node.new!(
              name: :a,
              action: Add,
              input: %{value: Ref.input(:value), amount: Ref.value(1)}
            )
          ],
          return: Ref.result(:d)
        )

      assert Enum.map(Flow.to_map(flow).nodes, & &1.name) == ["a", "b", "c", "d"]
      assert Enum.map(flow.nodes, & &1.name) == ["d", "c", "b", "a"]
    end

    test "canonical ordering keeps provenance attached to its node" do
      flow =
        Flow.new!(
          name: "provenance_order",
          nodes: [
            Node.new!(
              name: :z,
              action: Add,
              input: %{value: Ref.input(:value)},
              provenance: %{source_line: 30}
            ),
            Node.new!(
              name: :a,
              action: Add,
              input: %{value: Ref.input(:value)},
              provenance: %{source_line: 10}
            )
          ],
          return: Ref.result(:a),
          provenance: %{source: :test}
        )

      assert [
               %{name: "a", provenance: %{source_line: 10}},
               %{name: "z", provenance: %{source_line: 30}}
             ] = Flow.to_map(flow, provenance: true).nodes
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

    test "normalizes existing flow structs through construction" do
      raw_flow = %Flow{
        name: "raw_prebuilt",
        description: nil,
        schema: [],
        output_schema: [],
        nodes: [
          %Node{
            name: :add_one,
            action: Add,
            input: %{value: Ref.input(:value)},
            deps: [],
            provenance: %{}
          }
        ],
        return: %Ref{type: :result, node: :add_one, path: [:value]},
        provenance: %{}
      }

      assert {:ok, flow} = Flow.new(raw_flow)
      assert [%{name: "add_one"}] = flow.nodes
      assert flow.return.node == "add_one"
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
                 name: "audit",
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

      assert {:error,
              %InvalidInputError{message: "return must reference at least one step result"}} =
               Flow.new(name: "bad", nodes: [add_node()], return: Ref.value(:not_a_result))

      assert {:error,
              %InvalidInputError{message: "return must reference at least one step result"}} =
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
      assert details.node == "add_one"
      assert details.dependency == "missing"
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
      assert details.node == "audit"
      assert details.dependency == "missing"
    end

    test "emits a JSON-safe stored map with registry action identifiers" do
      flow =
        Flow.new!(
          name: "stored",
          schema: Zoi.object(%{items: Zoi.list(Zoi.any())}),
          output_schema: Zoi.object(%{total: Zoi.integer()}),
          nodes: [
            Node.new!(
              name: :add_one,
              action: Add,
              input: %{
                value: Ref.input([:items, 0, "price"]),
                amount: 1
              },
              provenance: %{line: 12}
            )
          ],
          return: %{total: Ref.result(:add_one, :value)},
          provenance: %{source: :test}
        )

      assert Flow.to_map(flow, format: :stored, actions: %{"add" => Add}) == %{
               "type" => "flow",
               "version" => 1,
               "name" => "stored",
               "description" => nil,
               "nodes" => [
                 %{
                   "name" => "add_one",
                   "action" => "add",
                   "input" => %{
                     "type" => "map",
                     "entries" => [
                       %{
                         "key" => %{"type" => "atom", "value" => "amount"},
                         "value" => %{"type" => "value", "value" => 1}
                       },
                       %{
                         "key" => %{"type" => "atom", "value" => "value"},
                         "value" => %{
                           "type" => "input",
                           "path" => [
                             %{"type" => "atom", "value" => "items"},
                             %{"type" => "integer", "value" => 0},
                             %{"type" => "string", "value" => "price"}
                           ]
                         }
                       }
                     ]
                   },
                   "deps" => []
                 }
               ],
               "return" => %{
                 "type" => "map",
                 "entries" => [
                   %{
                     "key" => %{"type" => "atom", "value" => "total"},
                     "value" => %{
                       "type" => "result",
                       "node" => "add_one",
                       "path" => [%{"type" => "atom", "value" => "value"}]
                     }
                   }
                 ]
               }
             }
    end

    test "includes provenance in stored maps only when requested" do
      node =
        Node.new!(
          name: :add_one,
          action: Add,
          input: %{value: Ref.input(:value)},
          provenance: %{line: 12, branch: :alpha}
        )

      flow =
        Flow.new!(
          name: "stored_provenance",
          nodes: [node],
          return: Ref.result(:add_one),
          provenance: %{source: :builder}
        )

      stored = Flow.to_map(flow, format: :stored, actions: %{"add" => Add})
      refute Map.has_key?(stored, "provenance")
      refute stored["nodes"] |> List.first() |> Map.has_key?("provenance")

      stored = Flow.to_map(flow, format: :stored, actions: %{"add" => Add}, provenance: true)

      assert stored["provenance"] == %{
               "$type" => "map",
               "entries" => [
                 %{
                   "key" => %{"type" => "atom", "value" => "source"},
                   "value" => %{"$type" => "atom", "value" => "builder"}
                 }
               ]
             }

      assert [%{"provenance" => node_provenance}] = stored["nodes"]

      assert node_provenance == %{
               "$type" => "map",
               "entries" => [
                 %{
                   "key" => %{"type" => "atom", "value" => "branch"},
                   "value" => %{"$type" => "atom", "value" => "alpha"}
                 },
                 %{
                   "key" => %{"type" => "atom", "value" => "line"},
                   "value" => 12
                 }
               ]
             }
    end

    test "rejects missing and ambiguous action registries when emitting stored maps" do
      flow =
        Flow.new!(
          name: "stored",
          nodes: [add_node()],
          return: Ref.result(:add_one, :value)
        )

      assert_raise InvalidInputError, ~r/missing flow action registry identifier/, fn ->
        Flow.to_map(flow, format: :stored, actions: %{})
      end

      assert_raise InvalidInputError, ~r/ambiguous flow action registry identifiers/, fn ->
        Flow.to_map(flow, format: :stored, actions: %{"add" => Add, "plus" => Add})
      end

      assert_raise InvalidInputError, ~r/flow action registry must map/, fn ->
        Flow.to_map(flow, format: :stored, actions: %{"add" => "not_module"})
      end

      assert_raise InvalidInputError, ~r/flow action registry must map/, fn ->
        Flow.to_map(flow, format: :stored, actions: [:not_a_keyword_pair])
      end
    end

    test "accepts keyword action registries when emitting stored maps" do
      flow =
        Flow.new!(
          name: "stored",
          nodes: [add_node()],
          return: Ref.result(:add_one, :value)
        )

      assert %{"nodes" => [%{"action" => "add"}]} =
               Flow.to_map(flow, format: :stored, actions: [add: Add])
    end

    test "rejects stored maps with unsupported expression keys and literal values" do
      tuple_key_flow =
        Flow.new!(
          name: "bad_key",
          nodes: [
            Node.new!(
              name: :echo,
              action: EchoParamsAction,
              input: %{{:tuple, :key} => Ref.value(1)}
            )
          ],
          return: Ref.result(:echo)
        )

      assert_raise InvalidInputError, ~r/stored flow map key is not JSON-safe/, fn ->
        Flow.to_map(tuple_key_flow, format: :stored, actions: %{"echo" => EchoParamsAction})
      end

      struct_value_flow =
        Flow.new!(
          name: "bad_struct_value",
          nodes: [
            Node.new!(
              name: :echo,
              action: EchoParamsAction,
              input: %{value: Ref.value(URI.parse("https://example.com"))}
            )
          ],
          return: Ref.result(:echo)
        )

      assert_raise InvalidInputError, ~r/stored flow value contains unsupported struct/, fn ->
        Flow.to_map(struct_value_flow,
          format: :stored,
          actions: %{"echo" => EchoParamsAction}
        )
      end

      assert {:error, %InvalidInputError{message: message}} =
               Flow.new(
                 name: "bad_opaque_value",
                 nodes: [
                   Node.new!(
                     name: :echo,
                     action: EchoParamsAction,
                     input: %{value: Ref.value(self())}
                   )
                 ],
                 return: Ref.result(:echo)
               )

      assert message =~ "Flow semantic data must be static module data"
      assert message =~ "runtime process values are not supported"
    end

    test "rejects unsupported map formats" do
      flow =
        Flow.new!(
          name: "stored",
          nodes: [add_node()],
          return: Ref.result(:add_one, :value)
        )

      assert_raise InvalidInputError, ~r/unsupported flow map format/, fn ->
        Flow.to_map(flow, format: :legacy)
      end
    end
  end

  describe "new!/1" do
    test "raises validation errors on invalid flow configuration" do
      assert_raise InvalidInputError, ~r/return ref is required/, fn ->
        Flow.new!(name: "bad", nodes: [[name: :add_one, action: Add]])
      end
    end
  end

  describe "from_map/2" do
    test "rejects mixed semantic and stored root discriminators before admission" do
      mixed = stored_flow_map() |> Map.put(:type, :flow)

      assert {:error,
              %InvalidInputError{
                message: "flow map cannot mix semantic and stored root keys",
                details: %{fields: [:type, "type"]}
              }} = Flow.from_map(mixed, stored_options(%{"add" => Add}))
    end

    test "admits stored maps at the width boundary and rejects boundary plus one" do
      exact = Map.new(1..10_000, &{Integer.to_string(&1), true})
      over_limit = Map.put(exact, "10001", true)

      assert {:ok, flow} =
               stored_flow_map()
               |> Map.put("provenance", exact)
               |> Flow.from_map(stored_options(%{"add" => Add}))

      assert map_size(flow.provenance) == 10_000

      assert {:error,
              %InvalidInputError{
                message: "stored flow map exceeds resource limit",
                details: details
              }} =
               stored_flow_map()
               |> Map.put("provenance", over_limit)
               |> Flow.from_map(stored_options(%{"add" => Add}))

      assert details == %{
               profile: :stored,
               resource: :collection_width,
               limit: 10_000,
               actual: 10_001,
               path: [{:map_value, 3}]
             }
    end

    test "rejects an over-width encoded entry list before duplicate processing" do
      stored = stored_flow_map()
      [entry | _] = get_in(stored, ["nodes", Access.at(0), "input", "entries"])

      over_limit =
        put_in(
          stored,
          ["nodes", Access.at(0), "input", "entries"],
          List.duplicate(entry, 10_001)
        )

      assert {:error,
              %InvalidInputError{
                message: "stored flow map exceeds resource limit",
                details: details
              }} = Flow.from_map(over_limit, stored_options(%{"add" => Add}))

      assert details.resource == :collection_width
      assert details.actual == 10_001
      refute inspect(details) =~ "encoded map contains a duplicate key"
    end

    test "keeps semantic maps outside the stored resource profile" do
      description = :binary.copy("x", 1_048_577)
      semantic = stored_source_flow() |> Flow.to_map() |> Map.put(:description, description)

      assert {:ok, %{description: ^description}} = Flow.from_map(semantic)
    end

    test "rejects reserved atom keys in every decoded encoded-map context" do
      encoded_reserved_map = %{
        "$type" => "map",
        "entries" => [
          %{
            "key" => %{"type" => "atom", "value" => "__struct__"},
            "value" => true
          }
        ]
      }

      expression =
        put_in(
          stored_flow_map(),
          ["nodes", Access.at(0), "input", "entries", Access.at(0), "key"],
          %{"type" => "atom", "value" => "__struct__"}
        )

      literal = stored_literal_map(encoded_reserved_map)
      root_provenance = Map.put(stored_flow_map(), "provenance", encoded_reserved_map)

      node_provenance =
        put_in(stored_flow_map(), ["nodes", Access.at(0), "provenance"], encoded_reserved_map)

      choice_provenance =
        choice_map_flow()
        |> Flow.to_map(
          format: :stored,
          actions: %{"echo" => EchoParamsAction, "add" => Add, "multiply" => Multiply}
        )
        |> put_in(["nodes", Access.at(1), "provenance"], encoded_reserved_map)

      cases = [
        {expression, stored_options(%{"add" => Add}), ["nodes", 0, "input", {:map_key, 0}]},
        {literal, stored_options(%{"add" => Add}),
         ["nodes", 0, "input", {:map_value, 0}, "value", {:map_key, 0}]},
        {root_provenance, stored_options(%{"add" => Add}), ["provenance", {:map_key, 0}]},
        {node_provenance, stored_options(%{"add" => Add}),
         ["nodes", 0, "provenance", {:map_key, 0}]},
        {choice_provenance,
         stored_options(%{
           "echo" => EchoParamsAction,
           "add" => Add,
           "multiply" => Multiply
         }), ["nodes", 1, "provenance", {:map_key, 0}]}
      ]

      for {artifact, options, path} <- cases do
        assert {:error,
                %InvalidInputError{
                  message: "stored flow map key is reserved: :__struct__",
                  details: details
                }} = Flow.from_map(artifact, options)

        assert details == %{record: :encoded_map, key: :__struct__, path: path}
      end
    end

    test "rejects reserved atom keys during stored encoding" do
      input = Map.put(%{}, :__struct__, Ref.value(1))

      expression_flow =
        Flow.new!(
          name: "reserved_writer_key",
          nodes: [Node.new!(name: :echo, action: EchoParamsAction, input: input)],
          return: Ref.result(:echo)
        )

      provenance_flow =
        Flow.new!(
          name: "reserved_writer_provenance",
          nodes: [Node.new!(name: :echo, action: EchoParamsAction, input: %{})],
          return: Ref.result(:echo),
          provenance: Map.put(%{}, :__struct__, "not a struct")
        )

      cases = [
        {expression_flow, ["nodes", 0, "input", {:map_key, 0}], []},
        {provenance_flow, ["provenance", {:map_key, 0}], [provenance: true]}
      ]

      for {flow, path, extra_options} <- cases do
        error =
          assert_raise InvalidInputError, fn ->
            Flow.to_map(
              flow,
              [format: :stored, actions: %{"echo" => EchoParamsAction}] ++ extra_options
            )
          end

        assert error.message == "stored flow map key is reserved: :__struct__"
        assert error.details == %{record: :encoded_map, key: :__struct__, path: path}
      end
    end

    test "allows binary __struct__ map keys and atom __struct__ path segments" do
      stored =
        stored_flow_map()
        |> put_in(
          ["nodes", Access.at(0), "input", "entries", Access.at(0), "key"],
          %{"type" => "string", "value" => "__struct__"}
        )
        |> Map.put("return", %{
          "type" => "result",
          "node" => "add_one",
          "path" => [%{"type" => "atom", "value" => "__struct__"}]
        })

      assert {:ok, flow} = Flow.from_map(stored, stored_options(%{"add" => Add}))
      assert [%{input: %{"__struct__" => _}}] = flow.nodes
      assert %Ref{path: [:__struct__]} = flow.return

      assert %{
               "nodes" => [%{"input" => %{"entries" => [%{"key" => string_key}]}}],
               "return" => %{"path" => [atom_segment]}
             } = Flow.to_map(flow, format: :stored, actions: %{"add" => Add})

      assert string_key == %{"type" => "string", "value" => "__struct__"}
      assert atom_segment == %{"type" => "atom", "value" => "__struct__"}
    end

    test "does not create atoms for rejected encoded map keys" do
      atom_name = "__jido_flow_map_key_#{System.unique_integer([:positive])}"
      assert_raise ArgumentError, fn -> String.to_existing_atom(atom_name) end

      stored =
        put_in(
          stored_flow_map(),
          ["nodes", Access.at(0), "input", "entries", Access.at(0), "key"],
          %{"type" => "atom", "value" => atom_name}
        )

      assert {:error, %InvalidInputError{message: message}} =
               Flow.from_map(stored, stored_options(%{"add" => Add}))

      assert message =~ "unknown atom in flow map"
      assert_raise ArgumentError, fn -> String.to_existing_atom(atom_name) end
    end

    test "round-trips tagged Choice records through semantic and stored maps" do
      flow = choice_map_flow()

      semantic = Flow.to_map(flow)

      assert [_, %{kind: :choice, name: "route", options: [first, second], fallback: fallback}] =
               semantic.nodes

      assert first.name == "priority"
      assert second.name == "standard"
      assert fallback.action == Multiply
      assert {:ok, semantic_loaded} = Flow.from_map(semantic)
      assert Flow.to_map(semantic_loaded) == semantic

      stored =
        flow
        |> Flow.to_map(
          format: :stored,
          actions: %{"echo" => EchoParamsAction, "add" => Add, "multiply" => Multiply}
        )
        |> JSON.encode!()
        |> JSON.decode!()

      assert [_, %{"kind" => "choice", "options" => [first, second], "fallback" => fallback}] =
               stored["nodes"]

      assert first["name"] == "priority"
      assert second["name"] == "standard"
      assert fallback["action"] == "multiply"

      assert {:ok, stored_loaded} =
               Flow.from_map(
                 stored,
                 stored_options(%{
                   "echo" => EchoParamsAction,
                   "add" => Add,
                   "multiply" => Multiply
                 })
               )

      assert Flow.to_map(stored_loaded) == semantic
    end

    test "rejects malformed Choice records before projection" do
      semantic = Flow.to_map(choice_map_flow())

      stored =
        choice_map_flow()
        |> Flow.to_map(
          format: :stored,
          actions: %{"echo" => EchoParamsAction, "add" => Add, "multiply" => Multiply}
        )

      malformed_semantic = update_in(semantic, [:nodes, Access.at(1)], &Map.delete(&1, :kind))

      assert {:error, %InvalidInputError{message: semantic_message, details: semantic_details}} =
               Flow.from_map(malformed_semantic)

      assert semantic_message =~ "choice"
      assert semantic_details.path == [:nodes, 1, :kind]

      malformed_stored =
        put_in(stored, ["nodes", Access.at(1), "options", Access.at(0), "extra"], true)

      assert {:error, %InvalidInputError{message: stored_message, details: stored_details}} =
               Flow.from_map(
                 malformed_stored,
                 stored_options(%{
                   "echo" => EchoParamsAction,
                   "add" => Add,
                   "multiply" => Multiply
                 })
               )

      assert stored_message =~ "unknown field"
      assert stored_details.path == ["nodes", 1, "options", 0, "extra"]

      unknown_target = put_in(stored, ["nodes", Access.at(1), "fallback", "action"], "missing")

      assert {:error, %InvalidInputError{message: unknown_message, details: unknown_details}} =
               Flow.from_map(
                 unknown_target,
                 stored_options(%{
                   "echo" => EchoParamsAction,
                   "add" => Add,
                   "multiply" => Multiply
                 })
               )

      assert unknown_message =~ "unknown flow action identifier"
      assert unknown_details.path == ["nodes", 1, "fallback", "action"]

      invalid_path =
        put_in(
          stored,
          [
            "nodes",
            Access.at(1),
            "options",
            Access.at(0),
            "condition",
            "operands",
            Access.at(0),
            "path"
          ],
          :invalid
        )

      assert {:error, %InvalidInputError{message: path_message}} =
               Flow.from_map(
                 invalid_path,
                 stored_options(%{
                   "echo" => EchoParamsAction,
                   "add" => Add,
                   "multiply" => Multiply
                 })
               )

      assert path_message == "flow ref path must be a list"
    end

    test "rejects malformed semantic Choice grammar with exact recursive paths" do
      semantic = Flow.to_map(choice_map_flow())

      cases = [
        {put_in(semantic, [:nodes, Access.at(1), :options], :not_a_list),
         "choice options must be a list", [:nodes, 1, :options]},
        {update_in(
           semantic,
           [:nodes, Access.at(1), :options, Access.at(0), :condition],
           &Map.delete(&1, :operator)
         ), "choice_condition is missing required field: :operator",
         [:nodes, 1, :options, 0, :condition, :operator]},
        {put_in(
           semantic,
           [:nodes, Access.at(1), :options, Access.at(0), :condition, :extra],
           true
         ), "choice_condition contains unknown field: :extra",
         [:nodes, 1, :options, 0, :condition, :extra]},
        {put_in(
           semantic,
           [:nodes, Access.at(1), :options, Access.at(0), :condition, :operator],
           :xor
         ), "unsupported choice condition operator",
         [:nodes, 1, :options, 0, :condition, :operator]},
        {put_in(
           semantic,
           [:nodes, Access.at(1), :options, Access.at(0), :condition, :operands],
           :not_a_list
         ), "choice condition operands must be a list",
         [:nodes, 1, :options, 0, :condition, :operands]},
        {put_in(semantic, [:nodes, Access.at(1), :fallback, :name], :otherwise),
         "choice fallback name must be fallback", [:nodes, 1, :fallback, :name]}
      ]

      actual =
        for {malformed, _expected_message, _expected_path} <- cases do
          assert {:error, %InvalidInputError{message: message, details: details}} =
                   Flow.from_map(malformed)

          {message, details.path}
        end

      expected =
        Enum.map(cases, fn {_malformed, message, path} ->
          {message, path}
        end)

      assert actual == expected
    end

    test "rejects malformed stored Choice grammar with exact recursive paths" do
      stored =
        choice_map_flow()
        |> Flow.to_map(
          format: :stored,
          actions: %{"echo" => EchoParamsAction, "add" => Add, "multiply" => Multiply}
        )

      cases = [
        {put_in(stored, ["nodes", Access.at(1), "options"], "not a list"),
         "choice options must be a list", ["nodes", 1, "options"]},
        {update_in(
           stored,
           ["nodes", Access.at(1), "options", Access.at(0), "condition"],
           &Map.delete(&1, "operator")
         ), ~s(choice_condition is missing required field: "operator"),
         ["nodes", 1, "options", 0, "condition", "operator"]},
        {put_in(
           stored,
           ["nodes", Access.at(1), "options", Access.at(0), "condition", "extra"],
           true
         ), ~s(choice_condition contains unknown field: "extra"),
         ["nodes", 1, "options", 0, "condition", "extra"]},
        {put_in(
           stored,
           ["nodes", Access.at(1), "options", Access.at(0), "condition", "operator"],
           "xor"
         ), "unsupported choice condition operator",
         ["nodes", 1, "options", 0, "condition", "operator"]},
        {put_in(
           stored,
           ["nodes", Access.at(1), "options", Access.at(0), "condition", "operands"],
           "not a list"
         ), "choice condition operands must be a list",
         ["nodes", 1, "options", 0, "condition", "operands"]},
        {put_in(stored, ["nodes", Access.at(1), "fallback", "name"], "otherwise"),
         "choice fallback name must be fallback", ["nodes", 1, "fallback", "name"]}
      ]

      options =
        stored_options(%{
          "echo" => EchoParamsAction,
          "add" => Add,
          "multiply" => Multiply
        })

      actual =
        for {malformed, _expected_message, _expected_path} <- cases do
          assert {:error, %InvalidInputError{message: message, details: details}} =
                   Flow.from_map(malformed, options)

          {message, details.path}
        end

      expected =
        Enum.map(cases, fn {_malformed, message, path} ->
          {message, path}
        end)

      assert actual == expected
    end

    test "requires one registry identifier for every Choice target during stored encoding" do
      flow = choice_map_flow()

      assert_raise InvalidInputError, ~r/missing flow action registry identifier/, fn ->
        Flow.to_map(flow, format: :stored, actions: %{"echo" => EchoParamsAction, "add" => Add})
      end

      assert_raise InvalidInputError, ~r/ambiguous flow action registry identifiers/, fn ->
        Flow.to_map(
          flow,
          format: :stored,
          actions: %{
            "echo" => EchoParamsAction,
            "add" => Add,
            "multiply" => Multiply,
            "times" => Multiply
          }
        )
      end
    end

    test "requires both explicit schema attachments for stored maps" do
      stored = stored_flow_map()
      actions = %{"add" => Add}

      for {opts, field} <- [
            {[actions: actions], :schema},
            {[actions: actions, schema: []], :output_schema},
            {[actions: actions, output_schema: []], :schema},
            {[actions: actions, schema: nil, output_schema: []], :schema},
            {[actions: actions, schema: [], output_schema: nil], :output_schema}
          ] do
        assert {:error, %InvalidInputError{message: message, details: details}} =
                 Flow.from_map(stored, opts)

        assert message == "stored flow requires external #{field} attachment"
        assert details.field == field
      end

      assert {:ok, flow} =
               Flow.from_map(stored, actions: actions, schema: [], output_schema: [])

      assert flow.schema == []
      assert flow.output_schema == []
    end

    test "rejects loader overrides for semantic maps and unknown loader options" do
      semantic = Flow.to_map(stored_source_flow())

      for {option, value} <- [
            actions: %{"add" => Add},
            schema: [],
            output_schema: []
          ] do
        assert {:error, %InvalidInputError{message: message, details: details}} =
                 Flow.from_map(semantic, [{option, value}])

        assert message == "semantic flow maps do not accept loader options"
        assert details.option == option
      end

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Flow.from_map(semantic, output_shema: [])

      assert message == "unknown flow map option: :output_shema"
      assert details.option == :output_shema
    end

    test "rejects duplicate loader keyword options" do
      actions = %{"add" => Add}

      for option <- [:actions, :schema, :output_schema] do
        opts = stored_options(actions)
        value = Keyword.fetch!(opts, option)

        assert {:error, %InvalidInputError{message: message, details: details}} =
                 Flow.from_map(stored_flow_map(), opts ++ [{option, value}])

        assert message == "duplicate flow map option: #{inspect(option)}"
        assert details.option == option
      end
    end

    test "rejects unknown fields throughout the stored recursive grammar" do
      stored = stored_flow_map()
      opts = [actions: %{"add" => Add}, schema: [], output_schema: []]

      [entry] = get_in(stored, ["nodes", Access.at(0), "input", "entries"])

      cases = [
        root: Map.put(stored, "extra", true),
        node: put_in(stored, ["nodes", Access.at(0), "extra"], true),
        reference:
          put_in(
            stored,
            ["nodes", Access.at(0), "input", "entries", Access.at(0), "value", "extra"],
            true
          ),
        encoded_map: put_in(stored, ["nodes", Access.at(0), "input", "extra"], true),
        entry:
          put_in(
            stored,
            ["nodes", Access.at(0), "input", "entries", Access.at(0)],
            Map.put(entry, "extra", true)
          ),
        typed_key:
          put_in(
            stored,
            ["nodes", Access.at(0), "input", "entries", Access.at(0), "key", "extra"],
            true
          ),
        typed_key:
          put_in(
            stored,
            ["nodes", Access.at(0), "input", "entries", Access.at(0), "value", "path"],
            [%{"type" => "atom", "value" => "value", "extra" => true}]
          )
      ]

      for {record, malformed} <- cases do
        assert {:error, %InvalidInputError{message: message, details: details}} =
                 Flow.from_map(malformed, opts)

        assert message =~ "unknown field"
        assert details.record == record
      end
    end

    test "rejects mixed profiles, aliases, embedded stored schemas, and duplicate entries" do
      stored = stored_flow_map()
      opts = [actions: %{"add" => Add}, schema: [], output_schema: []]

      malformed_maps = [
        Map.put(stored, :name, "alias"),
        put_in(stored, ["nodes", Access.at(0), :action], Add),
        Map.put(stored, "schema", []),
        Map.put(stored, :output_schema, [])
      ]

      for malformed <- malformed_maps do
        assert {:error, %InvalidInputError{message: message}} = Flow.from_map(malformed, opts)
        assert message =~ "unknown field"
      end

      [entry] = get_in(stored, ["nodes", Access.at(0), "input", "entries"])

      duplicate =
        put_in(stored, ["nodes", Access.at(0), "input", "entries"], [entry, entry])

      assert {:error, %InvalidInputError{message: message}} = Flow.from_map(duplicate, opts)
      assert message == "encoded map contains a duplicate key"
    end

    test "rejects mixed semantic structural aliases" do
      semantic = Flow.to_map(stored_source_flow())

      malformed_maps = [
        Map.put(semantic, "name", "alias"),
        put_in(semantic, [:nodes, Access.at(0), "action"], Add),
        put_in(semantic, [:nodes, Access.at(0), :input, :value, "path"], [])
      ]

      for malformed <- malformed_maps do
        assert {:error, %InvalidInputError{message: message}} = Flow.from_map(malformed)
        assert message =~ "unknown field"
      end
    end

    test "compile rejects malformed hand-built Flow structure before graph creation" do
      flow = %{stored_source_flow() | schema: Zoi.integer()}

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Flow.compile(flow)

      assert message == "schema must accept map-shaped action data"
      assert details.field == "schema"
    end

    test "loads a stored map decoded from JSON through an action registry" do
      flow =
        Flow.new!(
          name: "round_trip",
          nodes: [
            Node.new!(
              name: :add_one,
              action: Add,
              input: %{value: Ref.input([:items, 0, "price"]), amount: Ref.value(1)}
            )
          ],
          return: %{total: Ref.result(:add_one, :value)}
        )

      decoded =
        flow
        |> Flow.to_map(format: :stored, actions: %{"add" => Add})
        |> JSON.encode!()
        |> JSON.decode!()

      assert {:ok, loaded} = Flow.from_map(decoded, stored_options(%{"add" => Add}))
      assert Flow.to_map(loaded) == Flow.to_map(flow)
      assert {:ok, %{total: 42}} = Jido.Exec.run(loaded, %{items: [%{"price" => 41}]}, %{})
    end

    test "loads current semantic maps with module atoms and defers action contract checks" do
      missing_action = unique_module("StoredMissingAction")

      semantic_map = %{
        type: :flow,
        version: 1,
        name: "unchecked",
        description: nil,
        schema: [],
        output_schema: [],
        nodes: [
          %{
            name: "missing",
            action: missing_action,
            input: %{},
            deps: []
          }
        ],
        return: %{type: :result, node: "missing", path: []}
      }

      assert {:ok, flow} = Flow.from_map(semantic_map)
      assert {:error, %InvalidInputError{message: message, details: details}} = Flow.check(flow)
      assert message == "action module could not be loaded"
      assert details.action == missing_action
    end

    test "loads semantic maps with the current expression vocabulary" do
      flow =
        Flow.new!(
          name: "semantic_round_trip",
          nodes: [
            Node.new!(
              name: :echo,
              action: EchoParamsAction,
              input: %{
                value: Ref.input(:value),
                trace_id: Ref.context(:trace_id),
                literal: Ref.value(:ok)
              }
            )
          ],
          return: %{
            echoed: Ref.result(:echo),
            trace_id: Ref.context(:trace_id),
            literal: Ref.value(:ok)
          }
        )

      assert {:ok, loaded} = flow |> Flow.to_map() |> Flow.from_map(%{})
      assert Flow.to_map(loaded) == Flow.to_map(flow)
      assert {:ok, result} = Jido.Exec.run(loaded, %{value: 3}, %{trace_id: "trace-1"})
      assert result.echoed == %{value: 3, trace_id: "trace-1", literal: :ok}
      assert result.trace_id == "trace-1"
      assert result.literal == :ok
    end

    test "loads semantic maps with scalar expressions and non-ref type fields" do
      semantic_map = %{
        type: :flow,
        version: 1,
        name: "semantic_shape",
        description: nil,
        schema: [],
        output_schema: [],
        nodes: [
          %{
            name: "echo",
            action: EchoParamsAction,
            input: %{
              "type" => 123,
              "value" => %{type: :input, path: [:value]},
              "list" => [1, %{type: :input, path: [:value]}]
            },
            deps: []
          }
        ],
        return: %{type: :result, node: "echo", path: []}
      }

      assert {:ok, loaded} = Flow.from_map(semantic_map, %{})
      assert {:ok, result} = Jido.Exec.run(loaded, %{value: 3}, %{})
      assert result["type"] == 123
      assert result["value"] == 3
      assert result["list"] == [1, 3]
    end

    test "loads semantic result refs with atom and string node names" do
      semantic =
        Flow.new!(name: "semantic_result_node", nodes: [add_node()], return: Ref.result(:add_one))
        |> Flow.to_map()

      for node <- [:add_one, "add_one"] do
        assert {:ok, flow} =
                 semantic
                 |> put_in([:return, :node], node)
                 |> Flow.from_map()

        assert flow.return.node == "add_one"
      end
    end

    test "returns validation errors for invalid semantic result node fields" do
      semantic =
        Flow.new!(
          name: "invalid_semantic_result_node",
          nodes: [add_node()],
          return: Ref.result(:add_one)
        )
        |> Flow.to_map()

      for node <- [nil, 1] do
        assert {:error, %InvalidInputError{message: message, details: details}} =
                 semantic
                 |> put_in([:return, :node], node)
                 |> Flow.from_map()

        assert message == "semantic result ref node must be a non-nil atom or binary"
        assert details.node == node
      end
    end

    test "reattaches schemas from loader options" do
      flow =
        Flow.new!(
          name: "schema_round_trip",
          nodes: [add_node()],
          return: Ref.result(:add_one, :value)
        )

      stored = Flow.to_map(flow, format: :stored, actions: %{"add" => Add})

      assert {:ok, loaded} =
               Flow.from_map(stored,
                 actions: %{"add" => Add},
                 schema: Zoi.object(%{value: Zoi.integer()}),
                 output_schema: Zoi.object(%{value: Zoi.integer()})
               )

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Jido.Exec.run(loaded, %{value: "bad"}, %{})

      assert message =~ "expected integer"
      assert details.phase == :flow_input
    end

    test "round-trips typed expression keys and literal atom values" do
      flow =
        Flow.new!(
          name: "mixed_keys",
          nodes: [
            Node.new!(
              name: :echo,
              action: EchoParamsAction,
              input: %{
                "kind" => Ref.value(:left),
                1 => Ref.value("one"),
                value: Ref.input("value"),
                nested: %{"status" => Ref.value(:ok)}
              }
            )
          ],
          return: Ref.result(:echo)
        )

      decoded =
        flow
        |> Flow.to_map(format: :stored, actions: %{"echo" => EchoParamsAction})
        |> JSON.encode!()
        |> JSON.decode!()

      assert {:ok, loaded} =
               Flow.from_map(decoded, stored_options(%{"echo" => EchoParamsAction}))

      assert Flow.to_map(loaded) == Flow.to_map(flow)

      assert {:ok, result} = Jido.Exec.run(loaded, %{"value" => 3}, %{})
      assert result.value == 3
      assert result["kind"] == :left
      assert result[1] == "one"
      assert result.nested["status"] == :ok
    end

    test "rejects malformed stored maps with normalized validation errors" do
      assert {:error, %InvalidInputError{message: "flow map must be a map"}} =
               Flow.from_map(:not_a_map)

      assert {:error,
              %InvalidInputError{message: "flow map options must be a map or keyword list"}} =
               Flow.from_map(%{}, :not_options)

      assert {:error,
              %InvalidInputError{message: "flow map options must be a map or keyword list"}} =
               Flow.from_map(%{}, [:not_a_keyword_pair])

      assert {:error, %InvalidInputError{message: message}} =
               Flow.from_map(stored_flow_map(), stored_options(%{"add" => "not_module"}))

      assert message =~ "flow action registry must map"

      assert {:error, %InvalidInputError{message: "flow map version is required"}} =
               Flow.from_map(%{"type" => "flow"})

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Flow.from_map(%{"type" => "flow", "version" => 999})

      assert message =~ "unsupported flow map version"
      assert details.version == 999

      stored = %{
        "type" => "flow",
        "version" => 1,
        "name" => "bad",
        "nodes" => [
          %{
            "name" => "add_one",
            "action" => "missing",
            "input" => %{},
            "deps" => []
          }
        ],
        "return" => %{"type" => "result", "node" => "add_one", "path" => []}
      }

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Flow.from_map(stored, stored_options(%{}))

      assert message =~ "unknown flow action identifier"
      assert details.identifier == "missing"

      stored = put_in(stored, ["nodes", Access.at(0), "input"], %{"type" => "bogus"})

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Flow.from_map(stored, stored_options(%{"missing" => Add}))

      assert message =~ "unknown flow ref type"
      assert details.type == "bogus"
    end

    test "rejects additional malformed loader shapes" do
      base = %{
        "type" => "flow",
        "version" => 1,
        "name" => "bad",
        "nodes" => [
          %{
            "name" => "add_one",
            "action" => "add",
            "input" => %{
              "type" => "map",
              "entries" => [
                %{
                  "key" => %{"type" => "atom", "value" => "value"},
                  "value" => %{"type" => "input", "path" => []}
                }
              ]
            },
            "deps" => []
          }
        ],
        "return" => %{"type" => "result", "node" => "add_one", "path" => []}
      }

      assert {:error, %InvalidInputError{message: message, details: details}} =
               base
               |> Map.put("type", "workflow")
               |> Flow.from_map(stored_options(%{"add" => Add}))

      assert message =~ "flow map type must be flow"
      assert details.type == "workflow"

      assert {:error, %InvalidInputError{message: "flow nodes must be a list"}} =
               base
               |> Map.put("nodes", :not_nodes)
               |> Flow.from_map(stored_options(%{"add" => Add}))

      assert {:error, %InvalidInputError{message: "flow node must be a map"}} =
               base
               |> Map.put("nodes", [:not_node])
               |> Flow.from_map(stored_options(%{"add" => Add}))

      assert {:error, %InvalidInputError{message: message, details: details}} =
               base
               |> put_in(["nodes", Access.at(0), "action"], 123)
               |> Flow.from_map(stored_options(%{"add" => Add}))

      assert message =~ "stored flow node action must be a registered identifier"
      assert details.action == 123

      assert {:error, %InvalidInputError{message: message, details: details}} =
               base
               |> put_in(["nodes", Access.at(0), "input", "entries"], :not_entries)
               |> Flow.from_map(stored_options(%{"add" => Add}))

      assert message =~ "encoded map entries must be a list"
      assert details.entries == :not_entries

      assert {:error, %InvalidInputError{message: message, details: details}} =
               base
               |> put_in(["nodes", Access.at(0), "input", "entries"], [:not_entry])
               |> Flow.from_map(stored_options(%{"add" => Add}))

      assert message =~ "encoded map entry must be a map"
      assert details.entry == :not_entry

      assert {:error, %InvalidInputError{message: message, details: details}} =
               base
               |> put_in(["nodes", Access.at(0), "input", "entries", Access.at(0), "key"], :bad)
               |> Flow.from_map(stored_options(%{"add" => Add}))

      assert message =~ "malformed flow path segment"
      assert details.segment == :bad

      assert {:error, %InvalidInputError{message: message, details: details}} =
               base
               |> put_in(
                 ["nodes", Access.at(0), "input", "entries", Access.at(0), "value", "path"],
                 :bad
               )
               |> Flow.from_map(stored_options(%{"add" => Add}))

      assert message =~ "flow ref path must be a list"
      assert details.path == :bad

      assert {:error, %InvalidInputError{message: message, details: details}} =
               base
               |> Map.put("provenance", %{"$type" => "tuple", "value" => []})
               |> Flow.from_map(stored_options(%{"add" => Add}))

      assert message =~ "unknown encoded value type"
      assert details.type == "tuple"
    end

    test "returns validation errors for invalid stored result node fields" do
      stored =
        Flow.new!(
          name: "invalid_stored_result_node",
          nodes: [add_node()],
          return: Ref.result(:add_one)
        )
        |> Flow.to_map(format: :stored, actions: %{"add" => Add})

      for node <- [nil, 1, :add_one] do
        assert {:error, %InvalidInputError{message: message, details: details}} =
                 stored
                 |> put_in(["return", "node"], node)
                 |> Flow.from_map(stored_options(%{"add" => Add}))

        assert message == "stored result ref node must be a binary"
        assert details.node == node
      end
    end

    test "returns validation errors for non-binary stored encoded atom values" do
      for value <- [nil, 1, :ok] do
        assert {:error, %InvalidInputError{message: message, details: details}} =
                 value
                 |> then(&stored_literal_map(%{"$type" => "atom", "value" => &1}))
                 |> Flow.from_map(stored_options(%{"add" => Add}))

        assert message == "encoded atom value must be a binary"
        assert details.value == value
      end
    end

    test "loads plain JSON-shaped provenance maps" do
      stored = %{
        "type" => "flow",
        "version" => 1,
        "name" => "plain_provenance",
        "provenance" => %{
          "source" => "stored",
          "nested" => %{"kind" => "manual"}
        },
        "nodes" => [
          %{
            "name" => "echo",
            "action" => "echo",
            "input" => %{"type" => "map", "entries" => []},
            "deps" => []
          }
        ],
        "return" => %{"type" => "result", "node" => "echo", "path" => []}
      }

      assert {:ok, flow} =
               Flow.from_map(stored, stored_options(%{"echo" => EchoParamsAction}))

      assert flow.provenance == %{
               "source" => "stored",
               "nested" => %{"kind" => "manual"}
             }
    end

    test "loads direct JSON-safe stored data and tagged encodings" do
      encoded_map = %{
        "$type" => "map",
        "entries" => [
          %{
            "key" => %{"type" => "atom", "value" => "source"},
            "value" => %{"$type" => "atom", "value" => "writer"}
          }
        ]
      }

      values = [
        {nil, nil},
        {false, false},
        {1, 1},
        {1.5, 1.5},
        {"text", "text"},
        {["item", %{"nested" => true}], ["item", %{"nested" => true}]},
        {%{"nested" => [nil, "value"]}, %{"nested" => [nil, "value"]}},
        {%{"$type" => "atom", "value" => "ok"}, :ok},
        {encoded_map, %{source: :writer}}
      ]

      for {stored_value, value} <- values do
        assert {:ok, flow} =
                 stored_value
                 |> stored_literal_map()
                 |> Flow.from_map(stored_options(%{"add" => Add}))

        assert %{nodes: [%{input: %{value: %{type: :value, value: ^value}}}]} =
                 Flow.to_map(flow)
      end
    end

    test "rejects non-string stored plain-data and provenance map keys" do
      malformed_maps = [
        stored_literal_map(%{not_a_string: true}),
        Map.put(stored_flow_map(), "provenance", %{not_a_string: true})
      ]

      for stored <- malformed_maps do
        assert {:error, %InvalidInputError{message: message, details: details}} =
                 Flow.from_map(stored, stored_options(%{"add" => Add}))

        assert message == "stored plain data map contains a non-string key"
        assert details.record == :plain_data
        assert details.key == :not_a_string
      end
    end

    test "returns validation errors for opaque in-memory stored data" do
      improper_list = [1 | :tail]

      for value <- [improper_list, :opaque_atom, self(), fn -> :ok end, {:tuple}, make_ref()] do
        assert {:error, %InvalidInputError{message: message, details: details}} =
                 value
                 |> stored_literal_map()
                 |> Flow.from_map(stored_options(%{"add" => Add}))

        assert message == "stored flow value is not JSON-safe"
        assert is_binary(details.value)
      end
    end

    test "returns validation errors for improper structural lists" do
      stored =
        stored_flow_map()
        |> Map.put("return", %{"type" => "result", "node" => "add_one", "path" => []})

      [node] = stored["nodes"]
      [entry | _entries] = node["input"]["entries"]
      segment = %{"type" => "atom", "value" => "value"}

      cases = [
        {Map.put(stored, "nodes", [node | :tail]), "flow nodes must be a list"},
        {put_in(stored, ["nodes", Access.at(0), "deps"], ["other" | :tail]),
         "flow node deps must be a list"},
        {put_in(stored, ["return", "path"], [segment | :tail]), "flow ref path must be a list"},
        {put_in(stored, ["nodes", Access.at(0), "input", "entries"], [entry | :tail]),
         "encoded map entries must be a list"},
        {put_in(stored, ["nodes", Access.at(0), "input"], [
           %{"type" => "value", "value" => 1} | :tail
         ]), "flow expression must be a proper list"}
      ]

      for {malformed, expected_message} <- cases do
        assert {:error, %InvalidInputError{message: ^expected_message}} =
                 Flow.from_map(malformed, stored_options(%{"add" => Add}))
      end

      semantic =
        stored_source_flow()
        |> Flow.to_map()
        |> Map.put(:return, %{type: :result, node: :add_one, path: [:value | :tail]})

      assert {:error, %InvalidInputError{message: "flow ref path must be a list"}} =
               Flow.from_map(semantic)
    end

    test "rejects invalid values at each remaining recursive grammar boundary" do
      semantic = Flow.to_map(stored_source_flow())
      stored = stored_flow_map()
      options = stored_options(%{"add" => Add})

      cases = [
        {put_in(semantic, [:nodes, Access.at(0), :deps], :not_deps),
         "flow node deps must be a list"},
        {put_in(semantic, [:nodes, Access.at(0), :action], "not_a_module"),
         "semantic flow node action must be a module atom"},
        {put_in(semantic, [:return, :type], :unknown), "unknown flow ref type: :unknown"},
        {put_in(semantic, [:nodes, Access.at(0), :input, :value, :path], [1.5]),
         "flow ref path contains an invalid segment"},
        {put_in(semantic, [:nodes, Access.at(0), :input, :value, :path], :not_a_path),
         "flow ref path must be a list"}
      ]

      for {malformed, expected_message} <- cases do
        assert {:error, %InvalidInputError{message: ^expected_message}} =
                 Flow.from_map(malformed)
      end

      assert {:error,
              %InvalidInputError{message: "stored flow expression must be a tagged record"}} =
               stored
               |> put_in(["nodes", Access.at(0), "input", "entries", Access.at(0), "value"], 42)
               |> Flow.from_map(options)

      assert {:error, %InvalidInputError{message: message, details: details}} =
               stored
               |> update_in(
                 ["nodes", Access.at(0), "input", "entries", Access.at(0), "value"],
                 &Map.delete(&1, "path")
               )
               |> Flow.from_map(options)

      assert message == "reference is missing required field: \"path\""
      assert details.record == :reference
      assert details.field == "path"

      assert {:error, %InvalidInputError{message: "flow map type is required"}} =
               Flow.from_map(%{})
    end

    test "treats a non-reference semantic type field as ordinary shape data" do
      semantic =
        stored_source_flow()
        |> Flow.to_map()
        |> put_in([:nodes, Access.at(0), :input], %{
          type: 123,
          value: %{type: :value, value: :ok}
        })

      assert {:ok, flow} = Flow.from_map(semantic)
      assert [%Node{input: %{type: 123, value: %Ref{type: :value, value: :ok}}}] = flow.nodes
    end

    test "rejects opaque stored writer values in hand-built artifacts" do
      flow = %{stored_source_flow() | provenance: self()}

      assert_raise InvalidInputError, ~r/stored flow value is not JSON-safe/, fn ->
        Flow.to_map(flow,
          format: :stored,
          actions: %{"add" => Add},
          provenance: true
        )
      end
    end

    test "round-trips provenance emitted by the stored writer" do
      node =
        Node.new!(
          name: :add_one,
          action: Add,
          input: %{value: Ref.input(:value)},
          provenance: %{line: 12, labels: [:primary, "math"]}
        )

      flow =
        Flow.new!(
          name: "stored_provenance_round_trip",
          nodes: [node],
          return: Ref.result(:add_one),
          provenance: %{source: :writer, metadata: %{"revision" => 1}}
        )

      stored = Flow.to_map(flow, format: :stored, actions: %{"add" => Add}, provenance: true)

      assert {:ok, loaded} =
               Flow.from_map(stored, stored_options(%{"add" => Add}))

      assert loaded.provenance == flow.provenance
      assert [loaded_node] = loaded.nodes
      assert loaded_node.provenance == node.provenance
    end

    test "rejects nested malformed expression and metadata values" do
      base = %{
        "type" => "flow",
        "version" => 1,
        "name" => "bad_nested",
        "nodes" => [
          %{
            "name" => "echo",
            "action" => "echo",
            "input" => %{
              "type" => "map",
              "entries" => [
                %{
                  "key" => %{"type" => "atom", "value" => "value"},
                  "value" => %{"type" => "input", "path" => []}
                }
              ]
            },
            "deps" => []
          }
        ],
        "return" => %{"type" => "result", "node" => "echo", "path" => []}
      }

      assert {:error, %InvalidInputError{message: message, details: details}} =
               base
               |> put_in(
                 ["nodes", Access.at(0), "input", "entries", Access.at(0), "value"],
                 [
                   %{"type" => "value", "value" => 1},
                   %{"type" => "bogus"}
                 ]
               )
               |> Flow.from_map(stored_options(%{"echo" => EchoParamsAction}))

      assert message =~ "unknown flow ref type"
      assert details.type == "bogus"

      assert {:error, %InvalidInputError{message: message, details: details}} =
               base
               |> put_in(
                 ["nodes", Access.at(0), "input", "entries", Access.at(0), "value"],
                 %{
                   "nested" => %{"type" => "bogus"}
                 }
               )
               |> Flow.from_map(stored_options(%{"echo" => EchoParamsAction}))

      assert message == "stored flow expression must be a tagged record"
      assert details.record == :expression

      assert {:error, %InvalidInputError{message: message, details: details}} =
               base
               |> Map.put("provenance", %{
                 "source" => [
                   "ok",
                   %{"$type" => "bogus"}
                 ]
               })
               |> Flow.from_map(stored_options(%{"echo" => EchoParamsAction}))

      assert message =~ "unknown encoded value type"
      assert details.type == "bogus"

      assert {:error, %InvalidInputError{message: message, details: details}} =
               base
               |> Map.put("provenance", %{
                 "source" => %{"nested" => %{"$type" => "bogus"}}
               })
               |> Flow.from_map(stored_options(%{"echo" => EchoParamsAction}))

      assert message =~ "unknown encoded value type"
      assert details.type == "bogus"
    end

    test "rejects atom-key structural tags in stored path segments" do
      stored = %{
        "type" => "flow",
        "version" => 1,
        "name" => "atom_typed_segments",
        "nodes" => [
          %{
            "name" => "echo",
            "action" => "echo",
            "input" => %{
              "type" => "map",
              "entries" => [
                %{
                  "key" => %{type: :atom, value: "value"},
                  "value" => %{
                    "type" => "input",
                    "path" => [
                      %{type: :atom, value: "items"},
                      %{type: :integer, value: 0},
                      %{type: :string, value: "price"}
                    ]
                  }
                }
              ]
            },
            "deps" => []
          }
        ],
        "return" => %{"type" => "result", "node" => "echo", "path" => []}
      }

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Flow.from_map(stored, stored_options(echo: EchoParamsAction))

      assert message =~ "unknown field"
      assert details.record == :typed_key
    end

    test "rejects invalid action registry option shapes" do
      for actions <- [:bad, nil] do
        assert {:error, %InvalidInputError{message: message, details: details}} =
                 Flow.from_map(stored_flow_map(), stored_options(actions))

        assert message == "flow action registry must map string or atom identifiers to modules"
        assert details.actions == actions
      end
    end

    test "rejects unknown typed atom path segments without creating atoms" do
      atom_name = "__jido_flow_unknown_path_#{System.unique_integer([:positive])}"
      assert_raise ArgumentError, fn -> String.to_existing_atom(atom_name) end

      stored = %{
        "type" => "flow",
        "version" => 1,
        "name" => "bad_path",
        "nodes" => [
          %{
            "name" => "add_one",
            "action" => "add",
            "input" => %{
              "type" => "map",
              "entries" => [
                %{
                  "key" => %{"type" => "atom", "value" => "value"},
                  "value" => %{
                    "type" => "input",
                    "path" => [%{"type" => "atom", "value" => atom_name}]
                  }
                }
              ]
            },
            "deps" => []
          }
        ],
        "return" => %{"type" => "result", "node" => "add_one", "path" => []}
      }

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Flow.from_map(stored, stored_options(%{"add" => Add}))

      assert message =~ "unknown atom in flow map"
      assert details.value == atom_name
      assert_raise ArgumentError, fn -> String.to_existing_atom(atom_name) end
    end

    test "rejects malformed typed path segments" do
      stored = %{
        "type" => "flow",
        "version" => 1,
        "name" => "bad_segment",
        "nodes" => [
          %{
            "name" => "add_one",
            "action" => "add",
            "input" => %{
              "type" => "map",
              "entries" => [
                %{
                  "key" => %{"type" => "atom", "value" => "value"},
                  "value" => %{
                    "type" => "input",
                    "path" => [%{"type" => "float", "value" => 1.0}]
                  }
                }
              ]
            },
            "deps" => []
          }
        ],
        "return" => %{"type" => "result", "node" => "add_one", "path" => []}
      }

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Flow.from_map(stored, stored_options(%{"add" => Add}))

      assert message =~ "malformed flow path segment"
      assert details.type == "float"
      assert details.value == 1.0
    end
  end

  defp add_node do
    Node.new!(
      name: :add_one,
      action: Add,
      input: %{value: Ref.input(:value), amount: Ref.value(1)}
    )
  end

  defp stored_source_flow do
    Flow.new!(
      name: "stored_source",
      nodes: [Node.new!(name: :add_one, action: Add, input: %{value: Ref.input(:value)})],
      return: %{value: Ref.result(:add_one, :value)}
    )
  end

  defp choice_map_flow do
    Flow.new!(
      name: "choice_map",
      nodes: [
        Node.new!(name: :source, action: EchoParamsAction, input: %{kind: Ref.input(:kind)}),
        Choice.new!(
          name: :route,
          options: [
            [
              name: :priority,
              condition: Condition.eq(Ref.result(:source, :kind), :priority),
              action: Add,
              input: %{value: Ref.value(1), amount: Ref.value(1)}
            ],
            [
              name: :standard,
              condition: Condition.eq(Ref.input(:kind), :standard),
              action: Multiply,
              input: %{value: Ref.value(2), by: Ref.value(2)}
            ]
          ],
          fallback: [action: Multiply, input: %{value: Ref.value(3), by: Ref.value(3)}]
        )
      ],
      return: Ref.result(:route)
    )
  end

  defp stored_flow_map do
    stored_source_flow()
    |> Flow.to_map(format: :stored, actions: %{"add" => Add})
  end

  defp stored_literal_map(value) do
    put_in(
      stored_flow_map(),
      ["nodes", Access.at(0), "input", "entries", Access.at(0), "value"],
      %{"type" => "value", "value" => value}
    )
  end

  defp stored_options(actions) do
    [actions: actions, schema: [], output_schema: []]
  end
end
