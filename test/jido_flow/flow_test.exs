defmodule Jido.FlowTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Action.Error.InvalidInputError
  alias Jido.Flow
  alias Jido.Flow.{Node, Ref, Syntax}
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
          output_schema: Zoi.integer(),
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

      opaque_value_flow =
        Flow.new!(
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

      assert_raise InvalidInputError, ~r/stored flow value is not JSON-safe/, fn ->
        Flow.to_map(opaque_value_flow,
          format: :stored,
          actions: %{"echo" => EchoParamsAction}
        )
      end
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

      assert {:ok, loaded} = Flow.from_map(decoded, actions: %{"add" => Add})
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
                 output_schema: Zoi.integer()
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

      assert {:ok, loaded} = Flow.from_map(decoded, actions: %{"echo" => EchoParamsAction})
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
               Flow.from_map(%{}, actions: %{"add" => "not_module"})

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
               Flow.from_map(stored, actions: %{})

      assert message =~ "unknown flow action identifier"
      assert details.identifier == "missing"

      stored = put_in(stored, ["nodes", Access.at(0), "input"], %{"type" => "bogus"})

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Flow.from_map(stored, actions: %{"missing" => Add})

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
               base |> Map.put("type", "workflow") |> Flow.from_map(actions: %{"add" => Add})

      assert message =~ "flow map type must be flow"
      assert details.type == "workflow"

      assert {:error, %InvalidInputError{message: "flow nodes must be a list"}} =
               base |> Map.put("nodes", :not_nodes) |> Flow.from_map(actions: %{"add" => Add})

      assert {:error, %InvalidInputError{message: "flow node must be a map"}} =
               base |> Map.put("nodes", [:not_node]) |> Flow.from_map(actions: %{"add" => Add})

      assert {:error, %InvalidInputError{message: message, details: details}} =
               base
               |> put_in(["nodes", Access.at(0), "action"], 123)
               |> Flow.from_map(actions: %{"add" => Add})

      assert message =~ "flow node action must be a module atom or registered identifier"
      assert details.action == 123

      assert {:error, %InvalidInputError{message: message, details: details}} =
               base
               |> put_in(["nodes", Access.at(0), "input", "entries"], :not_entries)
               |> Flow.from_map(actions: %{"add" => Add})

      assert message =~ "encoded map entries must be a list"
      assert details.entries == :not_entries

      assert {:error, %InvalidInputError{message: message, details: details}} =
               base
               |> put_in(["nodes", Access.at(0), "input", "entries"], [:not_entry])
               |> Flow.from_map(actions: %{"add" => Add})

      assert message =~ "encoded map entry must be a map"
      assert details.entry == :not_entry

      assert {:error, %InvalidInputError{message: message, details: details}} =
               base
               |> put_in(["nodes", Access.at(0), "input", "entries", Access.at(0), "key"], :bad)
               |> Flow.from_map(actions: %{"add" => Add})

      assert message =~ "malformed flow path segment"
      assert details.segment == :bad

      assert {:error, %InvalidInputError{message: message, details: details}} =
               base
               |> put_in(
                 ["nodes", Access.at(0), "input", "entries", Access.at(0), "value", "path"],
                 :bad
               )
               |> Flow.from_map(actions: %{"add" => Add})

      assert message =~ "flow ref path must be a list"
      assert details.path == :bad

      assert {:error, %InvalidInputError{message: message, details: details}} =
               base
               |> Map.put("provenance", %{"$type" => "tuple", "value" => []})
               |> Flow.from_map(actions: %{"add" => Add})

      assert message =~ "unknown encoded value type"
      assert details.type == "tuple"
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
            "input" => %{},
            "deps" => []
          }
        ],
        "return" => %{"type" => "result", "node" => "echo", "path" => []}
      }

      assert {:ok, flow} = Flow.from_map(stored, actions: %{"echo" => EchoParamsAction})

      assert flow.provenance == %{
               "source" => "stored",
               "nested" => %{"kind" => "manual"}
             }
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
               |> Flow.from_map(actions: %{"echo" => EchoParamsAction})

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
               |> Flow.from_map(actions: %{"echo" => EchoParamsAction})

      assert message =~ "unknown flow ref type"
      assert details.type == "bogus"

      assert {:error, %InvalidInputError{message: message, details: details}} =
               base
               |> Map.put("provenance", %{
                 "source" => [
                   "ok",
                   %{"$type" => "bogus"}
                 ]
               })
               |> Flow.from_map(actions: %{"echo" => EchoParamsAction})

      assert message =~ "unknown encoded value type"
      assert details.type == "bogus"

      assert {:error, %InvalidInputError{message: message, details: details}} =
               base
               |> Map.put("provenance", %{
                 "source" => %{"nested" => %{"$type" => "bogus"}}
               })
               |> Flow.from_map(actions: %{"echo" => EchoParamsAction})

      assert message =~ "unknown encoded value type"
      assert details.type == "bogus"
    end

    test "loads in-memory stored maps with atom typed path segment tags" do
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

      assert {:ok, loaded} = Flow.from_map(stored, actions: [echo: EchoParamsAction])
      assert {:ok, %{value: 41}} = Jido.Exec.run(loaded, %{items: [%{"price" => 41}]}, %{})
    end

    test "rejects invalid action registry option shapes" do
      assert {:error, %InvalidInputError{message: message, details: details}} =
               Flow.from_map(%{}, actions: :bad)

      assert message =~ "flow action registry must map"
      assert details.actions == :bad
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
               Flow.from_map(stored, actions: %{"add" => Add})

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
               Flow.from_map(stored, actions: %{"add" => Add})

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
end
