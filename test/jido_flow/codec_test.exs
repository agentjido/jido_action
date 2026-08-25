defmodule Jido.Flow.CodecTest do
  use ExUnit.Case, async: true

  alias Jido.Flow.Error.InvalidDefinitionError
  alias Jido.Flow
  alias Jido.Flow.Choice
  alias Jido.Flow.Codec
  alias Jido.Flow.Condition
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
