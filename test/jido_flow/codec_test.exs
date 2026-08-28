defmodule Jido.Flow.CodecTest do
  use ExUnit.Case, async: true

  alias Jido.Flow.Error.InvalidDefinitionError
  alias Jido.Flow
  alias Jido.Flow.Choice
  alias Jido.Flow.Codec
  alias Jido.Flow.Condition
  alias Jido.Flow.Error
  alias Jido.Flow.Ref
  alias Jido.Flow.Registry
  alias Jido.Flow.Step
  alias Jido.Flow.Subflow
  alias JidoActionTest.Fixtures.CodecRegistry
  alias JidoActionTest.Fixtures.FlowAuthoring
  alias JidoActionTest.Fixtures.NestedFlow
  alias JidoActionTest.Fixtures.Actions.{Add, Multiply}

  test "JSON bytes round trip to the equal canonical Flow" do
    flow = FlowAuthoring.mixed_flow!()
    registry = CodecRegistry.mixed()

    assert {:ok, document} = Codec.encode(flow, registry)
    assert document["version"] == 1

    assert Enum.map(document["components"], & &1["kind"]) ==
             ["step", "subflow", "choice", "map", "reduce", "iterate"]

    json = Jason.encode!(document)
    decoded_document = Jason.decode!(json)

    assert {:ok, decoded} = Codec.decode(decoded_document, registry)
    assert decoded == flow
    assert {:ok, ^document} = Codec.encode(decoded, registry)
    assert {:ok, ^flow} = Codec.diagnose(decoded_document, registry)
  end

  test "encode/1 returns a generated convenience Registry" do
    flow = FlowAuthoring.mixed_flow!()

    assert {:ok, document, registry} = Codec.encode(flow)
    assert {:ok, ^flow} = Codec.decode(document, registry)
    assert {:ok, ^document, ^registry} = Codec.encode(flow)

    assert {:error, %InvalidDefinitionError{}} = Codec.encode(:invalid)
  end

  test "diagnose returns ordered errors from independent document branches" do
    flow = FlowAuthoring.mixed_flow!()
    registry = CodecRegistry.mixed()
    assert {:ok, document} = Codec.encode(flow, registry)

    [step, subflow, choice | rest] = document["components"]
    [option] = choice["options"]

    step = step |> Map.put("after", 42) |> Map.put("action", 42)

    option =
      option
      |> Map.put("condition", true)
      |> Map.put("action", 42)

    fallback = Map.put(choice["fallback"], "action", "actions/missing")
    choice = %{choice | "options" => [option], "fallback" => fallback}

    output = %{
      "$type" => "map",
      "entries" => [
        %{
          "key" => "first",
          "value" => %{"$type" => "atom", "id" => 42}
        },
        %{
          "key" => "second",
          "value" => %{"$type" => "atom", "id" => "atoms/missing"}
        }
      ]
    }

    invalid = %{
      document
      | "components" => [step, subflow, choice | rest],
        "output" => output
    }

    assert {:error, %Error.Invalid{errors: errors} = aggregate} =
             Codec.diagnose(invalid, registry)

    assert Enum.map(errors, & &1.details.path) == [
             ["components", 0, "after"],
             ["components", 0, "action"],
             ["components", 2, "options", 0, "condition"],
             ["components", 2, "options", 0, "action"],
             ["components", 2, "fallback", "action"],
             ["output", "entries", 0, "value", "id"],
             ["output", "entries", 1, "value", "id"]
           ]

    assert %{details: %{errors: stable_errors}} = Error.to_map(aggregate)
    assert length(stable_errors) == 7
    assert is_binary(JSON.encode!(aggregate))
  end

  test "diagnose reports all unknown graph references without cycle cascades" do
    flow = FlowAuthoring.math_flow!()
    registry = CodecRegistry.mixed()
    assert {:ok, document} = Codec.encode(flow, registry)

    [first, second] = document["components"]
    first = %{first | "after" => ["missing-first"]}
    second = %{second | "after" => ["missing-second"]}

    output = %{
      "$ref" => %{
        "source" => "result",
        "component" => "missing-output",
        "path" => []
      }
    }

    invalid = %{document | "components" => [first, second], "output" => output}

    assert {:error, %Error.Invalid{errors: errors}} = Codec.diagnose(invalid, registry)

    assert Enum.map(errors, fn error ->
             {error.details.owner, error.details.component, error.details.path}
           end) == [
             {:output, "missing-output", ["output"]},
             {"add_one", "missing-first", ["components", 0]},
             {"double", "missing-second", ["components", 1]}
           ]
  end

  test "diagnose stops at document safety limits" do
    registry = CodecRegistry.mixed()
    assert {:ok, document} = Codec.encode(FlowAuthoring.mixed_flow!(), registry)
    unsafe = %{document | "output" => List.duplicate(0, 10_001)}

    assert {:error,
            %Error.Invalid{
              errors: [
                %InvalidDefinitionError{
                  message: "stored Flow collection exceeds its size limit"
                }
              ]
            }} = Codec.diagnose(unsafe, registry)
  end

  test "diagnose contains invalid public boundaries and root envelopes" do
    registry = CodecRegistry.mixed()
    assert {:ok, document} = Codec.encode(FlowAuthoring.mixed_flow!(), registry)

    for {invalid, invalid_registry} <- [
          {:not_a_document, registry},
          {document, :not_a_registry}
        ] do
      assert {:error, %Error.Invalid{errors: [_error]}} =
               Codec.diagnose(invalid, invalid_registry)
    end

    envelope_errors =
      document
      |> Map.delete("type")
      |> Map.put("version", 99)
      |> Map.put("extra", true)

    assert {:error, %Error.Invalid{errors: envelope}} =
             Codec.diagnose(envelope_errors, registry)

    assert Enum.map(envelope, & &1.details.path) == [["extra"], ["type"], ["version"]]

    missing_fields =
      Enum.reduce(
        ["name", "description", "schema", "output_schema", "components", "output"],
        document,
        &Map.delete(&2, &1)
      )

    assert {:error, %Error.Invalid{errors: missing}} = Codec.diagnose(missing_fields, registry)
    assert length(missing) == 6

    invalid_fields = %{
      document
      | "name" => 42,
        "description" => 42,
        "schema" => 42,
        "output_schema" => 42,
        "components" => :not_a_list,
        "output" => %{"bad" => true}
    }

    assert {:error, %Error.Invalid{errors: invalid}} = Codec.diagnose(invalid_fields, registry)
    assert length(invalid) == 6

    assert {:ok, nil_description} = Codec.diagnose(%{document | "description" => nil}, registry)
    assert nil_description.description == nil

    assert {:error, %Error.Invalid{errors: [name_error]}} =
             Codec.diagnose(%{document | "name" => ""}, registry)

    assert name_error.details.path == ["name"]

    bad_schema_registry =
      Registry.new!(%{
        "actions/add" => {:action, Add},
        "actions/multiply" => {:action, Multiply},
        "flows/nested" => {:flow, NestedFlow},
        "schemas/bad" => {:schema, fn -> :not_static end},
        "atoms/add" => {:atom, :add},
        "atoms/amount" => {:atom, :amount},
        "atoms/count" => {:atom, :count},
        "atoms/items" => {:atom, :items},
        "atoms/kind" => {:atom, :kind},
        "atoms/owner" => {:atom, :owner},
        "atoms/value" => {:atom, :value}
      })

    bad_schemas = %{document | "schema" => "schemas/bad", "output_schema" => "schemas/bad"}

    assert {:error, %Error.Invalid{errors: schema_errors}} =
             Codec.diagnose(bad_schemas, bad_schema_registry)

    assert Enum.map(schema_errors, & &1.details.path) == [
             ["schema"],
             ["output_schema"],
             ["components", 5, "state", "schema"]
           ]
  end

  test "diagnose collects required fields for every component kind" do
    registry = CodecRegistry.mixed()
    assert {:ok, document} = Codec.encode(FlowAuthoring.mixed_flow!(), registry)
    [step, subflow, choice, map, reduce, iterate] = document["components"]

    step =
      step
      |> Map.delete("action")
      |> Map.delete("params")
      |> Map.delete("meta")
      |> Map.put("extra", true)

    subflow = %{subflow | "flow" => 42, "after" => [42]}
    choice = choice |> Map.delete("options") |> Map.delete("fallback")

    map =
      map
      |> Map.delete("collection")
      |> Map.delete("action")
      |> Map.delete("params")
      |> Map.put("on_error", "unsupported")

    reduce =
      reduce
      |> Map.delete("initial")
      |> Map.delete("params")
      |> Map.put("collection", %{"bad" => true})
      |> Map.put("action", 42)

    iterate =
      iterate
      |> Map.delete("action")
      |> Map.delete("params")
      |> Map.delete("state")
      |> Map.delete("completion")
      |> Map.put("max_iterations", 0)

    invalid = %{document | "components" => [step, subflow, choice, map, reduce, iterate]}

    assert {:error, %Error.Invalid{errors: errors}} = Codec.diagnose(invalid, registry)
    assert length(errors) == 21

    assert errors
           |> Enum.map(& &1.details.path)
           |> Enum.all?(&match?(["components", _index | _rest], &1))
  end

  test "diagnose collects nested reference, condition, list, and map errors" do
    registry = CodecRegistry.mixed()
    assert {:ok, document} = Codec.encode(FlowAuthoring.mixed_flow!(), registry)
    choice = Enum.at(document["components"], 2)
    [option] = choice["options"]

    condition = %{
      "$condition" => %{
        "operator" => "all",
        "operands" => [true, false]
      }
    }

    option = %{option | "condition" => condition}
    choice = %{choice | "options" => [nil, option]}

    bad_ref = %{
      "$ref" => %{
        "source" => "unsupported",
        "component" => 42,
        "path" => :not_a_list,
        "extra" => true
      }
    }

    output = [
      bad_ref,
      %{"$type" => "atom"},
      %{"$type" => "map", "entries" => :not_a_list}
    ]

    invalid = replace_component(document, 2, choice) |> Map.put("output", output)

    assert {:error, %Error.Invalid{errors: errors}} = Codec.diagnose(invalid, registry)
    assert length(errors) == 9

    duplicate_map = %{
      "$type" => "map",
      "entries" => [
        %{"key" => "same", "value" => 1},
        %{"key" => "same", "value" => 2}
      ]
    }

    assert {:error, %Error.Invalid{errors: [duplicate]}} =
             Codec.diagnose(%{document | "output" => duplicate_map}, registry)

    assert duplicate.details.path == ["output", "entries", 1, "key"]

    invalid_entries = %{
      "$type" => "map",
      "entries" => [
        nil,
        %{"key" => "missing-value"},
        %{"value" => 1},
        %{"key" => %{"$type" => "map", "entries" => []}, "value" => 1}
      ]
    }

    assert {:error, %Error.Invalid{errors: entry_errors}} =
             Codec.diagnose(%{document | "output" => invalid_entries}, registry)

    assert length(entry_errors) == 4
  end

  test "diagnose distinguishes duplicate names and dependency cycles" do
    registry = CodecRegistry.mixed()

    flow =
      Flow.new!(
        name: "diagnostic_graph",
        components: [
          Step.new!(name: "first", action: Add),
          Step.new!(name: "second", action: Add)
        ],
        output: %{}
      )

    assert {:ok, document} = Codec.encode(flow, registry)
    [first, second] = document["components"]

    duplicate = %{document | "components" => [first, %{second | "name" => first["name"]}]}

    assert {:error, %Error.Invalid{errors: [duplicate_error]}} =
             Codec.diagnose(duplicate, registry)

    assert duplicate_error.details.path == ["components", 1, "name"]

    cycle = %{
      document
      | "components" => [
          %{first | "after" => [second["name"]]},
          %{second | "after" => [first["name"]]}
        ]
    }

    assert {:error, %Error.Invalid{errors: [cycle_error]}} = Codec.diagnose(cycle, registry)
    assert cycle_error.message == "flow dependency graph contains a cycle"
    assert cycle_error.details.path == ["components"]
  end

  test "Codec rejects invalid UTF-8 at every portable string boundary" do
    invalid = <<255>>
    registry = CodecRegistry.storage()

    step = Step.new!(name: "stored", action: Add, params: %{value: "valid"})

    flow =
      Flow.new!(
        name: "utf8_boundary",
        description: "valid",
        components: [step],
        output: Ref.result("stored")
      )

    invalid_flows = [
      %{flow | description: invalid},
      %{flow | components: [%{step | params: %{value: invalid}}]},
      %{flow | components: [%{step | params: %{invalid => "value"}}]},
      %{flow | components: [%{step | meta: %{owner: invalid}}]}
    ]

    for invalid_flow <- invalid_flows do
      assert {:error, %InvalidDefinitionError{}} = Codec.encode(invalid_flow, registry)
    end

    assert {:error, %InvalidDefinitionError{}} =
             Registry.new(%{invalid => {:action, Add}})

    assert {:ok, document} = Codec.encode(flow, registry)

    assert {:error, %InvalidDefinitionError{}} =
             Codec.decode(%{document | "description" => invalid}, registry)

    assert {:ok, decoded} =
             document
             |> Jason.encode!()
             |> Jason.decode!()
             |> Codec.decode(registry)

    assert decoded == flow
  end

  test "the decoder rejects an unsupported version and missing component kinds" do
    {:ok, document} = Codec.encode(FlowAuthoring.mixed_flow!(), CodecRegistry.mixed())

    assert {:error, %InvalidDefinitionError{}} =
             Codec.decode(%{document | "version" => 99}, CodecRegistry.mixed())

    [first | rest] = document["components"]
    invalid = %{document | "components" => [Map.delete(first, "kind") | rest]}
    assert {:error, %InvalidDefinitionError{}} = Codec.decode(invalid, CodecRegistry.mixed())
  end

  test "Codec rejects invalid public boundary values and root records" do
    registry = CodecRegistry.mixed()
    flow = FlowAuthoring.mixed_flow!()
    assert {:ok, document} = Codec.encode(flow, registry)

    assert {:error, %InvalidDefinitionError{}} = Codec.encode(:invalid, registry)
    assert {:error, %InvalidDefinitionError{}} = Codec.encode(flow, :invalid)
    assert {:error, %InvalidDefinitionError{}} = Codec.decode(:invalid, registry)
    assert {:error, %InvalidDefinitionError{}} = Codec.decode(document, :invalid)

    for invalid <- [Map.delete(document, "name"), Map.put(document, "extra", true)] do
      assert {:error, %InvalidDefinitionError{}} = Codec.decode(invalid, registry)
    end
  end

  test "Action and Flow identifiers have distinct trusted kinds" do
    flow =
      Flow.new!(
        name: "one_subflow",
        components: [Subflow.new!(name: "child", flow: NestedFlow)],
        output: Ref.result("child")
      )

    wrong_registry =
      Registry.new!(%{
        "targets/child" => {:action, NestedFlow},
        "schemas/empty" => {:schema, []}
      })

    assert {:error, %InvalidDefinitionError{}} = Codec.encode(flow, wrong_registry)

    document = %{
      "type" => "jido.flow",
      "version" => 1,
      "name" => "one_subflow",
      "description" => nil,
      "schema" => "schemas/empty",
      "output_schema" => "schemas/empty",
      "components" => [
        %{
          "kind" => "subflow",
          "name" => "child",
          "flow" => "targets/child",
          "params" => %{"$type" => "map", "entries" => []},
          "after" => [],
          "meta" => %{"$type" => "map", "entries" => []}
        }
      ],
      "output" => %{
        "$ref" => %{"source" => "result", "component" => "child", "path" => []}
      }
    }

    assert {:error, %InvalidDefinitionError{}} = Codec.decode(document, wrong_registry)
  end

  test "unknown module text is never resolved without a Registry entry" do
    {:ok, document} = Codec.encode(FlowAuthoring.mixed_flow!(), CodecRegistry.mixed())
    [step | rest] = document["components"]
    unknown_identifier = "untrusted/action/#{System.unique_integer([:positive])}"
    document = %{document | "components" => [%{step | "action" => unknown_identifier} | rest]}

    refute existing_atom?(unknown_identifier)

    assert {:error, %InvalidDefinitionError{}} =
             Codec.decode(document, CodecRegistry.mixed())

    refute existing_atom?(unknown_identifier)
  end

  test "JSON bytes preserve string, integer, and registered atom map keys" do
    registry = CodecRegistry.storage()

    flow =
      Flow.new!(
        name: "stored_key_types",
        components: [
          Step.new!(
            name: "keys",
            action: Add,
            params: %{
              "string-key" => "value",
              7 => [%{:atom_key => :ready}],
              :atom_key => %{9 => :ready}
            },
            meta: %{
              "owner" => %{1 => :ready, :atom_key => "meta"},
              "tags" => ["stored", "portable"]
            }
          )
        ],
        output: Ref.result("keys")
      )

    assert {:ok, document} = Codec.encode(flow, registry)

    assert {:ok, decoded} =
             document |> Jason.encode!() |> Jason.decode!() |> Codec.decode(registry)

    assert decoded == flow
    assert {:ok, ^document} = Codec.encode(decoded, registry)
  end

  test "Codec rejects values above its nesting and collection limits" do
    registry = CodecRegistry.mixed()
    flow = FlowAuthoring.mixed_flow!()
    assert {:ok, document} = Codec.encode(flow, registry)

    deep_output = Enum.reduce(1..102, 0, fn _index, nested -> [nested] end)
    wide_output = List.duplicate(0, 10_001)

    assert {:error,
            %InvalidDefinitionError{
              message: "stored Flow exceeds its nesting limit",
              details: %{maximum_depth: 100}
            }} = Codec.decode(%{document | "output" => deep_output}, registry)

    assert {:error,
            %InvalidDefinitionError{
              message: "stored Flow collection exceeds its size limit",
              details: %{maximum_size: 10_000}
            }} = Codec.decode(%{document | "output" => wide_output}, registry)

    deep_flow = Flow.new!(name: "deep_encode", components: flow.components, output: deep_output)
    wide_flow = Flow.new!(name: "wide_encode", components: flow.components, output: wide_output)

    assert {:error, %InvalidDefinitionError{message: "stored Flow exceeds its nesting limit"}} =
             Codec.encode(deep_flow, registry)

    assert {:error,
            %InvalidDefinitionError{message: "stored Flow collection exceeds its size limit"}} =
             Codec.encode(wide_flow, registry)

    assert {:error,
            %InvalidDefinitionError{message: "stored Flow collection exceeds its size limit"}} =
             Codec.decode(
               %{document | "components" => List.duplicate(hd(document["components"]), 10_001)},
               registry
             )

    choice = Enum.at(document["components"], 2)

    assert {:error,
            %InvalidDefinitionError{message: "stored Flow collection exceeds its size limit"}} =
             Codec.decode(
               replace_component(document, 2, %{choice | "options" => List.duplicate(%{}, 10_001)}),
               registry
             )
  end

  test "Codec bounds total decode work across permitted collections" do
    registry = CodecRegistry.mixed()
    assert {:ok, document} = Codec.encode(FlowAuthoring.mixed_flow!(), registry)

    large_but_locally_valid = List.duplicate(List.duplicate(0, 10_000), 11)

    assert {:error,
            %InvalidDefinitionError{
              message: "stored Flow exceeds its total node limit",
              details: %{maximum_nodes: 100_000}
            }} = Codec.decode(%{document | "output" => large_but_locally_valid}, registry)
  end

  test "nested conditions use one tagged JSON grammar" do
    flow =
      Flow.new!(
        name: "nested_condition",
        components: [
          Choice.new!(
            name: "route",
            options: [
              Choice.Option.new!(
                name: "nested",
                condition:
                  Condition.all([
                    Condition.eq(Ref.input(:kind), :go),
                    Condition.not(Condition.eq(Ref.input(:value), 0))
                  ]),
                action: Add
              )
            ],
            fallback: Choice.Fallback.new!(action: Add)
          )
        ],
        output: Ref.result("route")
      )

    assert {:ok, document} = Codec.encode(flow, CodecRegistry.mixed())
    assert {:ok, ^flow} = Codec.decode(document, CodecRegistry.mixed())
  end

  test "the encoder reports a missing trusted action inside a Choice option" do
    flow =
      Flow.new!(
        name: "unregistered_choice_action",
        components: [
          Choice.new!(
            name: "route",
            options: [
              Choice.Option.new!(
                name: "multiply",
                condition: Condition.eq(1, 1),
                action: Multiply
              )
            ],
            fallback: Choice.Fallback.new!(action: Add)
          )
        ],
        output: Ref.result("route")
      )

    registry =
      Registry.new!(%{
        "actions/add" => {:action, Add},
        "schemas/empty" => {:schema, []}
      })

    assert {:error, %InvalidDefinitionError{}} = Codec.encode(flow, registry)
  end

  test "the decoder rejects malformed nested stored records" do
    assert {:ok, document} =
             Codec.encode(FlowAuthoring.mixed_flow!(), CodecRegistry.mixed())

    [step | _rest] = document["components"]
    choice = Enum.at(document["components"], 2)
    iterate = Enum.at(document["components"], 5)
    [option] = choice["options"]

    duplicate_map = %{
      "$type" => "map",
      "entries" => [
        %{"key" => "same", "value" => 1},
        %{"key" => "same", "value" => 2}
      ]
    }

    invalid_documents = [
      %{document | "components" => []},
      %{document | "components" => [nil]},
      replace_component(document, 2, %{choice | "options" => []}),
      replace_component(document, 2, %{choice | "options" => "invalid"}),
      replace_component(document, 2, %{choice | "options" => [nil]}),
      replace_component(
        document,
        2,
        %{choice | "options" => [%{option | "condition" => true}]}
      ),
      replace_component(
        document,
        2,
        %{
          choice
          | "options" => [
              %{
                option
                | "condition" => %{
                    "$condition" => %{"operator" => "all", "operands" => "invalid"}
                  }
              }
            ]
        }
      ),
      %{document | "output" => %{"$type" => "atom", "id" => 42}},
      %{document | "output" => %{"$type" => "atom", "id" => "atoms/missing"}},
      %{document | "output" => duplicate_map},
      %{
        document
        | "output" => %{
            "$type" => "map",
            "entries" => [nil]
          }
      },
      replace_component(document, 0, %{step | "action" => 42}),
      %{document | "description" => 42},
      replace_component(document, 0, %{step | "after" => 42}),
      replace_component(document, 5, %{iterate | "max_iterations" => 0}),
      replace_component(document, 5, %{iterate | "state" => 42}),
      replace_component(document, 2, %{choice | "fallback" => 42})
    ]

    for invalid <- invalid_documents do
      assert {:error, %InvalidDefinitionError{}} = Codec.decode(invalid, CodecRegistry.mixed())

      assert {:error, %Error.Invalid{errors: [_first | _rest]}} =
               Codec.diagnose(invalid, CodecRegistry.mixed())
    end
  end

  defp replace_component(document, index, component) do
    %{document | "components" => List.replace_at(document["components"], index, component)}
  end

  defp existing_atom?(value) do
    _atom = String.to_existing_atom(value)
    true
  rescue
    ArgumentError -> false
  end
end
