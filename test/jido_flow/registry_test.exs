defmodule Jido.Flow.RegistryTest do
  use ExUnit.Case, async: true

  alias Jido.Action.Error
  alias Jido.Flow
  alias Jido.Flow.{Choice, Condition, Iterator, Node, Ref, Registry, State}
  alias JidoTest.TestActions.Add

  test "builds one flat typed registry" do
    schema = Zoi.map(%{value: Zoi.integer()})

    assert {:ok, registry} =
             Registry.new(%{
               "action/add/v1" => {:action, Add},
               "schema/value/v1" => {:schema, schema}
             })

    assert {:ok, Add} = Registry.resolve(registry, "action/add/v1", :action)
    assert {:ok, ^schema} = Registry.resolve(registry, "schema/value/v1", :schema)
    assert {:ok, "action/add/v1"} = Registry.identifier(registry, :action, Add)
  end

  test "rejects unsafe identifiers and untyped entries" do
    assert {:error, error} = Registry.new(%{("Elixir.Bad" <> <<0>>) => {:action, Add}})
    assert Exception.message(error) =~ "identifier"

    assert {:error, error} = Registry.new(%{"action/add/v1" => Add})
    assert Exception.message(error) =~ "entry"

    assert {:error, error} = Registry.new(%{add: {:action, Add}})
    assert Exception.message(error) =~ "identifier"
  end

  test "does not load an Action while it validates trusted host entries" do
    module =
      Module.concat([JidoTest, "UnloadedRegistryAction#{System.unique_integer([:positive])}"])

    refute Code.loaded?(module)

    assert {:ok, registry} = Registry.new(%{"action/unloaded/v1" => {:action, module}})
    assert {:ok, ^module} = Registry.resolve(registry, "action/unloaded/v1", :action)
    refute Code.loaded?(module)
  end

  test "requires one identifier for each semantic value" do
    registry =
      Registry.new!(%{
        "action/add/v1" => {:action, Add},
        "action/add/alias" => {:action, Add}
      })

    assert {:error, error} = Registry.identifier(registry, :action, Add)
    assert Exception.message(error) =~ "multiple identifiers"
  end

  test "does not create atoms while it rejects AI-produced identifiers" do
    identifier = "unknown_#{System.unique_integer([:positive])}"

    assert_raise ArgumentError, fn -> String.to_existing_atom(identifier) end
    assert {:error, _error} = Registry.new(%{identifier => {:unknown_kind, Add}})
    assert_raise ArgumentError, fn -> String.to_existing_atom(identifier) end
  end

  test "stores and restores a complete Flow through one flat registry" do
    state_schema = Zoi.object(%{value: Zoi.integer()})

    flow =
      Flow.new!(
        name: "stored_math",
        schema: [],
        output_schema: [],
        nodes: [
          Node.new!(
            name: "seed",
            action: Add,
            input: %{value: Ref.input(:value), amount: Ref.value(1)}
          ),
          Iterator.new!(
            name: "count",
            action: Add,
            input: %{value: Ref.state(:value), amount: Ref.value(1)},
            state:
              State.new!(
                schema: state_schema,
                initial: %{value: Ref.result("seed", :value)},
                update: Ref.body_result()
              ),
            completion: %Condition{
              operator: :gte,
              operands: [Ref.state(:value), Ref.value(3)]
            },
            max_iterations: 5
          )
        ],
        return: Ref.result("count")
      )

    registry =
      Registry.new!(%{
        "action/add/v1" => {:action, Add},
        "schema/empty/v1" => {:schema, []},
        "schema/count/v1" => {:schema, state_schema}
      })

    assert {:ok, stored} = Flow.to_stored_map(flow, registry)
    assert stored["version"] == 1
    refute Map.has_key?(stored, "contracts")
    assert stored["input_schema"] == "schema/empty/v1"
    assert get_in(stored, ["nodes", Access.at(1), "state", "schema"]) == "schema/count/v1"

    json = Jason.encode!(stored)
    assert {:ok, restored} = json |> Jason.decode!() |> Flow.from_stored_map(registry)
    assert Flow.to_map(restored) == Flow.to_map(flow)
  end

  test "stored data cannot select a module outside the host registry" do
    registry =
      Registry.new!(%{
        "action/add/v1" => {:action, Add},
        "schema/empty/v1" => {:schema, []}
      })

    flow =
      Flow.new!(
        name: "safe",
        nodes: [Node.new!(name: "add", action: Add)],
        return: Ref.result("add")
      )

    assert {:ok, stored} = Flow.to_stored_map(flow, registry)
    unknown = "unknown_action_#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end

    malformed = put_in(stored, ["nodes", Access.at(0), "action"], unknown)
    assert {:error, error} = Flow.from_stored_map(malformed, registry)
    assert Exception.message(error) =~ "unknown flow registry identifier"
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
  end

  test "stored input keeps structural resource limits" do
    registry = Registry.new!(%{})

    stored = %{
      "type" => "flow",
      "version" => 1,
      "name" => "large",
      "description" => String.duplicate("x", 1_048_577),
      "input_schema" => "schema/empty/v1",
      "output_schema" => "schema/empty/v1",
      "nodes" => [],
      "return" => %{"type" => "value", "value" => nil}
    }

    assert {:error, error} = Flow.from_stored_map(stored, registry)
    assert Exception.message(error) == "stored flow map exceeds resource limit"
  end

  test "returns structured feedback for an incomplete runtime map without raising" do
    registry = Registry.new!(%{})
    candidate = %{"type" => "flow", "version" => 1}

    assert {:error, error} = Flow.from_stored_map(candidate, registry)

    assert Jido.Action.Error.to_map(error) == %{
             type: :validation_error,
             message: "root is missing required field: \"name\"",
             details: %{record: :root, field: "name"},
             retryable?: false
           }
  end

  test "uses base version one and rejects other versions" do
    {stored, registry} = stored_step()
    assert stored["version"] == 1

    for version <- [0, 2] do
      assert {:error, error} =
               stored
               |> Map.put("version", version)
               |> Flow.from_stored_map(registry)

      assert Exception.message(error) == "unsupported flow map version: #{version}"
    end
  end

  test "rejects unknown fields at the root and inside a node" do
    {stored, registry} = stored_step()

    assert {:error, root_error} =
             stored
             |> Map.put("unexpected", true)
             |> Flow.from_stored_map(registry)

    assert Exception.message(root_error) =~ "root contains unknown field"

    malformed_node =
      update_in(stored, ["nodes", Access.at(0)], &Map.put(&1, "unexpected", true))

    assert {:error, node_error} = Flow.from_stored_map(malformed_node, registry)
    assert Exception.message(node_error) =~ "node contains unknown field"
  end

  test "rejects unknown atom keys without creating atoms" do
    {stored, registry} = stored_step()
    unknown = "unknown_key_#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end

    malformed = Map.put(stored, "return", encoded_atom_key_return(unknown))
    assert {:error, error} = Flow.from_stored_map(malformed, registry)
    assert Exception.message(error) =~ "unknown atom in flow map"
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
  end

  test "rejects a decoded __struct__ atom key" do
    {stored, registry} = stored_step()
    malformed = Map.put(stored, "return", encoded_atom_key_return("__struct__"))

    assert {:error, error} = Flow.from_stored_map(malformed, registry)
    assert Exception.message(error) == "stored flow map key is reserved: :__struct__"
  end

  test "keeps identifier kind authority during stored reads and writes" do
    {stored, registry} = stored_step()

    malformed =
      put_in(stored, ["nodes", Access.at(0), "action"], "schema/empty/v1")

    assert {:error, read_error} = Flow.from_stored_map(malformed, registry)
    assert Exception.message(read_error) =~ "wrong entry kind"

    flow = step_flow()
    missing_action = Registry.new!(%{"schema/empty/v1" => {:schema, []}})
    assert {:error, missing_error} = Flow.to_stored_map(flow, missing_action)
    assert Exception.message(missing_error) =~ "no identifier"

    ambiguous =
      Registry.new!(%{
        "action/add/a" => {:action, Add},
        "action/add/b" => {:action, Add},
        "schema/empty/v1" => {:schema, []}
      })

    assert {:error, ambiguous_error} = Flow.to_stored_map(flow, ambiguous)
    assert Exception.message(ambiguous_error) =~ "multiple identifiers"
  end

  test "accepts plain JSON provenance and stores tagged trusted data losslessly" do
    flow =
      Flow.new!(
        name: "data_round_trip",
        provenance: %{source: :host},
        nodes: [
          Node.new!(
            name: "add",
            action: Add,
            input: %{
              payload: Ref.value(%{"string_key" => [1, true, nil], atom_key: :ready})
            },
            provenance: %{line: 12}
          )
        ],
        return: Ref.result("add")
      )

    registry = registry()
    assert {:ok, stored} = Flow.to_stored_map(flow, registry, provenance: true)

    assert {:ok, restored} =
             stored
             |> Jason.encode!()
             |> Jason.decode!()
             |> then(&Flow.from_stored_map(&1, registry))

    assert Flow.to_map(restored, provenance: true) == Flow.to_map(flow, provenance: true)

    ai_stored = Map.put(stored, "provenance", %{"source" => "ai"})
    assert {:ok, ai_restored} = Flow.from_stored_map(ai_stored, registry)
    assert ai_restored.provenance == %{"source" => "ai"}
  end

  test "round-trips Choice targets through the same flat Action entries" do
    choice =
      Choice.new!(
        name: "route",
        options: [
          [
            name: "matched",
            condition: Condition.eq(Ref.input(:kind), "add"),
            action: Add,
            input: %{value: Ref.input(:value)}
          ]
        ],
        fallback: [action: Add, input: %{value: Ref.value(0)}]
      )

    flow = Flow.new!(name: "stored_choice", nodes: [choice], return: Ref.result("route"))
    registry = registry()

    assert {:ok, stored} = Flow.to_stored_map(flow, registry)

    assert {:ok, restored} =
             stored
             |> Jason.encode!()
             |> Jason.decode!()
             |> then(&Flow.from_stored_map(&1, registry))

    assert Flow.to_map(restored) == Flow.to_map(flow)
  end

  test "rejects trusted values that cannot be stored as JSON" do
    flow =
      Flow.new!(
        name: "bad_provenance",
        provenance: %{runtime: self()},
        nodes: [Node.new!(name: "add", action: Add)],
        return: Ref.result("add")
      )

    assert {:error, error} = Flow.to_stored_map(flow, registry(), provenance: true)
    assert Exception.message(error) == "stored flow value is not JSON-safe"
    assert error.details.path == ["provenance", {:map_value, 0}]
  end

  test "rejects an improper list in trusted data without raising" do
    flow =
      Flow.new!(
        name: "improper_provenance",
        provenance: %{items: [1 | :tail]},
        nodes: [Node.new!(name: "add", action: Add)],
        return: Ref.result("add")
      )

    assert {:error, error} = Flow.to_stored_map(flow, registry(), provenance: true)
    assert Exception.message(error) == "stored flow value is not JSON-safe"
    assert error.details.path == ["provenance", {:map_value, 0}]
  end

  test "rejects invalid UTF-8 before it returns a stored map" do
    flow =
      Flow.new!(
        name: "invalid_utf8",
        nodes: [
          Node.new!(name: "add", action: Add, input: %{value: Ref.value(<<255>>)})
        ],
        return: Ref.result("add")
      )

    assert {:error, error} = Flow.to_stored_map(flow, registry())
    assert Exception.message(error) == "stored flow map contains invalid UTF-8"
    assert error.details.profile == :stored
    assert is_list(error.details.path)
    assert is_binary(error |> Error.to_map() |> JSON.encode!())
  end

  test "does not write a stored map that exceeds the reader resource budget" do
    flow =
      Flow.new!(
        name: "oversize",
        nodes: [
          Node.new!(
            name: "add",
            action: Add,
            input: %{value: Ref.value(String.duplicate("a", 1_048_577))}
          )
        ],
        return: Ref.result("add")
      )

    assert {:error, error} = Flow.to_stored_map(flow, registry())
    assert Exception.message(error) == "stored flow map exceeds resource limit"
    assert error.details.resource == :binary_bytes
  end

  test "normalizes Registry structs and rejects invalid public inputs" do
    registry = registry()
    assert {:ok, ^registry} = Registry.new(registry)

    assert {:error, error} = Registry.new(:invalid)
    assert Exception.message(error) == "flow registry must be a map"

    new_registry! = &Registry.new!/1
    assert_raise Error.InvalidInputError, fn -> new_registry!.(:invalid) end

    refute Registry.valid_identifier?(nil)
    refute Registry.valid_identifier?("")
    refute Registry.valid_identifier?(String.duplicate("a", 256))

    assert {:error, error} = Registry.resolve(registry, "bad identifier!", :action)
    assert Exception.message(error) == "invalid flow registry identifier"
  end

  test "bounds invalid Registry diagnostics and enforces its entry limit" do
    too_large = Map.new(1..10_001, fn index -> {"action/#{index}", {:action, Add}} end)

    assert {:error, error} = Registry.new(too_large)
    assert Exception.message(error) == "flow registry exceeds its entry limit"
    assert error.details.maximum_entries == 10_000

    invalid_identifiers = [
      String.duplicate("a", 256),
      :atom,
      1,
      [],
      %{},
      {:tuple},
      self()
    ]

    for identifier <- invalid_identifiers do
      assert {:error, error} = Registry.new(%{identifier => {:action, Add}})
      assert Exception.message(error) == "invalid flow registry identifier"
    end
  end

  test "classifies invalid Registry entry shapes without inspecting executable data" do
    invalid_entries = [:atom, "binary", 1, [], %{}, {:unknown, Add}, self()]

    for entry <- invalid_entries do
      assert {:error, error} = Registry.new(%{"entry/v1" => entry})
      assert Exception.message(error) == "invalid flow registry entry"
    end

    assert {:error, _error} = Registry.new(%{"action/nil/v1" => {:action, nil}})
    assert {:error, _error} = Registry.new(%{"action/string/v1" => {:action, "not-a-module"}})
  end

  defp stored_step do
    registry = registry()
    assert {:ok, stored} = Flow.to_stored_map(step_flow(), registry)
    {stored, registry}
  end

  defp step_flow do
    Flow.new!(
      name: "safe",
      nodes: [Node.new!(name: "add", action: Add)],
      return: Ref.result("add")
    )
  end

  defp registry do
    Registry.new!(%{
      "action/add/v1" => {:action, Add},
      "schema/empty/v1" => {:schema, []}
    })
  end

  defp encoded_atom_key_return(atom_name) do
    %{
      "type" => "value",
      "value" => %{
        "$type" => "map",
        "entries" => [
          %{
            "key" => %{"type" => "atom", "value" => atom_name},
            "value" => 1
          }
        ]
      }
    }
  end
end
