defmodule Jido.Flow.RefactorCharacterizationTest do
  use ExUnit.Case, async: true

  alias Jido.Flow
  alias Jido.Flow.{Compiler, MapCodec, Node, Ref, Registry}
  alias JidoTest.TestActions.Add

  test "keeps the Flow, MapCodec, and Compiler facade exports stable" do
    assert MapCodec.__info__(:functions) == [
             from_stored_map: 2,
             to_semantic_map: 3,
             to_stored_map: 4,
             to_stored_map!: 4
           ]

    assert Compiler.__info__(:functions) == [
             runtime_result: 4,
             runtime_workflow_validated: 6
           ]

    assert Flow.__info__(:functions) == [
             __struct__: 0,
             __struct__: 1,
             __validate_config__: 1,
             canonical_nodes: 1,
             dependencies: 1,
             explain: 1,
             from_stored_map: 2,
             new: 1,
             new!: 1,
             semantic_identity: 1,
             to_map: 1,
             to_map: 2,
             to_stored_map: 2,
             to_stored_map: 3,
             validate: 1,
             validate_executable: 1
           ]

    assert Flow.__info__(:macros) == [__before_compile__: 1, __using__: 1]
  end

  test "keeps the representative stored-map shape stable" do
    flow =
      Flow.new!(
        name: "codec_characterization",
        description: "stable",
        nodes: [
          Node.new!(
            name: "add",
            action: Add,
            input: %{
              :amount => Ref.value(2),
              "value" => Ref.input(:value)
            },
            provenance: %{line: 7}
          )
        ],
        return: Ref.result("add", :value),
        provenance: %{source: "test"}
      )

    assert {:ok, stored} = Flow.to_stored_map(flow, registry(), provenance: true)

    assert stored == %{
             "type" => "flow",
             "version" => 1,
             "name" => "codec_characterization",
             "description" => "stable",
             "input_schema" => "schema/empty/v1",
             "output_schema" => "schema/empty/v1",
             "nodes" => [
               %{
                 "name" => "add",
                 "action" => "action/add/v1",
                 "input" => %{
                   "type" => "map",
                   "entries" => [
                     %{
                       "key" => %{"type" => "atom", "value" => "amount"},
                       "value" => %{"type" => "value", "value" => 2}
                     },
                     %{
                       "key" => %{"type" => "string", "value" => "value"},
                       "value" => %{
                         "type" => "input",
                         "path" => [%{"type" => "atom", "value" => "value"}]
                       }
                     }
                   ]
                 },
                 "deps" => [],
                 "provenance" => %{
                   "$type" => "map",
                   "entries" => [
                     %{
                       "key" => %{"type" => "atom", "value" => "line"},
                       "value" => 7
                     }
                   ]
                 }
               }
             ],
             "return" => %{
               "type" => "result",
               "node" => "add",
               "path" => [%{"type" => "atom", "value" => "value"}]
             },
             "provenance" => %{
               "$type" => "map",
               "entries" => [
                 %{
                   "key" => %{"type" => "atom", "value" => "source"},
                   "value" => "test"
                 }
               ]
             }
           }

    assert {:ok, restored} =
             stored |> Jason.encode!() |> Jason.decode!() |> Flow.from_stored_map(registry())

    assert Flow.to_map(restored, provenance: true) == Flow.to_map(flow, provenance: true)
  end

  test "keeps nested decoder and encoder error paths stable" do
    flow =
      Flow.new!(
        name: "codec_errors",
        nodes: [Node.new!(name: "add", action: Add, input: %{amount: Ref.value(2)})],
        return: Ref.result("add")
      )

    assert {:ok, stored} = Flow.to_stored_map(flow, registry())

    invalid =
      put_in(
        stored,
        ["nodes", Access.at(0), "input", "entries", Access.at(0), "value"],
        %{"type" => "unknown"}
      )

    assert {:error, error} = Flow.from_stored_map(invalid, registry())
    assert error.message == "unknown flow ref type: \"unknown\""
    assert error.details == %{type: "unknown", path: ["nodes", 0, "input", {:map_value, 0}]}

    invalid_provenance = %{flow | provenance: %{bad: self()}}

    assert {:error, error} =
             Flow.to_stored_map(invalid_provenance, registry(), provenance: true)

    assert error.message == "stored flow value is not JSON-safe"
    assert error.details.path == ["provenance", {:map_value, 0}]
  end

  defp registry do
    Registry.new!(%{
      "action/add/v1" => {:action, Add},
      "schema/empty/v1" => {:schema, []}
    })
  end
end
