defmodule JidoActionTest.Flow.MapTest do
  use ExUnit.Case, async: true

  alias Jido.Action.Error.InvalidInputError
  alias Jido.Flow.Map, as: FlowMap
  alias Jido.Flow.Ref
  alias JidoActionTest.FlowFixtures.NestedFlow
  alias JidoActionTest.TestActions.{Add, MissingRun}

  describe "new/1" do
    test "raises from new!/1 on an invalid canonical Map" do
      assert_raise InvalidInputError, fn ->
        FlowMap.new!(name: :bad, collection: [], action: nil)
      end
    end

    test "builds the closed canonical contract and keeps provenance non-semantic" do
      assert {:ok, map} =
               FlowMap.new(
                 name: :enrich,
                 collection: Ref.input(:items),
                 action: Add,
                 input: %{
                   item: Ref.item(),
                   index: Ref.item_index(),
                   item_id: Ref.item_id(),
                   prior: Ref.result(:load, :value)
                 },
                 on_error: :collect_errors,
                 deps: [:load, "prepare", :load],
                 provenance: %{line: 12}
               )

      assert map.name == "enrich"
      assert map.on_error == :collect_errors
      assert map.deps == ["load", "prepare"]

      assert FlowMap.result_deps(map) == ["load", "prepare"]

      assert FlowMap.to_map(map) == %{
               kind: :map,
               name: "enrich",
               collection: %{type: :input, path: [:items]},
               action: Add,
               input: %{
                 item: %{type: :item, path: []},
                 index: %{type: :item_index},
                 item_id: %{type: :item_id},
                 prior: %{type: :result, node: "load", path: [:value]}
               },
               on_error: :collect_errors,
               deps: ["load", "prepare"]
             }

      refute Map.has_key?(FlowMap.to_map(map), :provenance)
      assert FlowMap.to_map(map, provenance: true).provenance == %{line: 12}
    end

    test "uses stable empty defaults" do
      assert {:ok, map} =
               FlowMap.new(name: "empty", collection: [], action: Add, input: nil)

      assert map.input == %{}
      assert map.on_error == :fail_fast
      assert map.deps == []
      assert map.provenance == %{}
    end

    test "rejects malformed configurations with exact paths" do
      cases = [
        {:not_a_map, "map configuration must be a map", []},
        {%{collection: [], action: Add}, "map name must be a non-empty string or atom", [:name]},
        {%{name: :bad, action: Add}, "map collection is required", [:collection]},
        {%{name: :bad, collection: [], action: "bad"}, "map target must be a module atom",
         [:action]},
        {%{name: :bad, collection: [], action: Add, on_error: :continue},
         "map on_error must be :fail_fast or :collect_errors", [:on_error]},
        {%{name: :bad, collection: [1 | :tail], action: Add},
         "map collection must be a proper list", [:collection]},
        {%{name: :bad, collection: [], action: Add, deps: :bad}, "map deps must be a list",
         [:deps]},
        {%{name: :bad, collection: [], action: Add, deps: [:ok | :tail]},
         "map deps must be a proper list", [:deps]},
        {%{name: :bad, collection: [], action: Add, deps: [:ok, nil]},
         "map deps must be a list of step names", [:deps]},
        {%{name: :bad, collection: [], action: Add, provenance: :bad},
         "map provenance must be a map", [:provenance]},
        {%{name: :bad, collection: [], action: Add, unexpected: true},
         "unknown map configuration key: :unexpected", [:unexpected]}
      ]

      for {attrs, expected_message, expected_path} <- cases do
        assert {:error,
                %InvalidInputError{message: ^expected_message, details: %{path: ^expected_path}}} =
                 FlowMap.new(attrs)
      end
    end

    test "enforces collection and target-input ref scopes at nested paths" do
      assert {:error, %InvalidInputError{message: message, details: details}} =
               FlowMap.new(name: :bad, collection: Ref.item(), action: Add)

      assert message == "flow expression contains a scoped ref outside its valid scope"
      assert details.path == [:collection]
      assert details.ref_type == :item
      assert details.scope == :map_collection

      assert {:error, %InvalidInputError{message: message, details: details}} =
               FlowMap.new(
                 name: :bad,
                 collection: [],
                 action: Add,
                 input: %{nested: [Ref.accumulator()]}
               )

      assert message == "flow expression contains a scoped ref outside its valid scope"
      assert details.path == [:input, :nested, 0]
      assert details.ref_type == :accumulator
      assert details.scope == :map_input

      assert {:error, %InvalidInputError{message: message, details: details}} =
               FlowMap.new(name: :bad, collection: Date.utc_today(), action: Add)

      assert message == "map collection contains unsupported expression"
      assert details.path == [:collection]
      assert details.expression == Date
    end

    test "revalidates improper structs" do
      valid = FlowMap.new!(name: :valid, collection: [], action: Add)

      assert {:error, %InvalidInputError{message: "map deps must be a proper list"}} =
               FlowMap.new(%{valid | deps: [:load | :tail]})
    end
  end

  test "preflights a target without invoking it" do
    assert :ok ==
             FlowMap.new!(name: :valid, collection: [], action: Add)
             |> FlowMap.check()

    assert {:error, %InvalidInputError{message: message, details: details}} =
             FlowMap.new!(name: :bad, collection: [], action: MissingRun)
             |> FlowMap.check()

    assert message =~ "module is not a valid Jido action"
    assert details.map == "bad"
    assert details.target == MissingRun
  end

  test "accepts a marked nested Flow target" do
    assert :ok =
             FlowMap.new!(name: :nested, collection: [], action: NestedFlow)
             |> FlowMap.check()
  end
end
