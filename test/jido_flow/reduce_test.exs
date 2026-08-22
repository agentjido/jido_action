defmodule Jido.Flow.ReduceTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Action.Error.InvalidInputError
  alias Jido.Action.Output
  alias Jido.Flow.Reduce
  alias Jido.Flow.Ref
  alias JidoTest.TestActions.{Add, MissingRun}

  describe "new/1" do
    test "raises from new!/1 on an invalid canonical Reduce" do
      assert_raise InvalidInputError, fn ->
        Reduce.new!(name: :bad, collection: [], initial: %{}, action: nil)
      end
    end

    test "builds the closed canonical contract with every local ref" do
      assert {:ok, reduce} =
               Reduce.new(
                 name: :summarize,
                 collection: Ref.result(:enrich),
                 initial: Ref.value(%{total: 0}),
                 action: Add,
                 input: %{
                   accumulator: Ref.accumulator(),
                   total: Ref.accumulator(:total),
                   item: Ref.item(),
                   index: Ref.item_index(),
                   item_id: Ref.item_id(),
                   prior: Ref.result(:prepare)
                 },
                 deps: [:prepare, :enrich],
                 provenance: %{line: 22}
               )

      assert reduce.name == "summarize"
      assert reduce.deps == ["enrich", "prepare"]
      assert Reduce.result_deps(reduce) == ["enrich", "prepare"]

      assert Reduce.to_map(reduce) == %{
               kind: :reduce,
               name: "summarize",
               collection: %{type: :result, node: "enrich", path: []},
               initial: %{type: :value, value: %{total: 0}},
               action: Add,
               input: %{
                 accumulator: %{type: :accumulator, path: []},
                 total: %{type: :accumulator, path: [:total]},
                 item: %{type: :item, path: []},
                 index: %{type: :item_index},
                 item_id: %{type: :item_id},
                 prior: %{type: :result, node: "prepare", path: []}
               },
               deps: ["enrich", "prepare"]
             }

      refute Map.has_key?(Reduce.to_map(reduce), :provenance)
      assert Reduce.to_map(reduce, provenance: true).provenance == %{line: 22}
    end

    test "keeps an empty list and Output-shaped initial expression as data" do
      initial = Ref.value(Output.raw(%{total: 0}))

      assert {:ok, reduce} =
               Reduce.new(
                 name: :empty,
                 collection: [],
                 initial: initial,
                 action: Add,
                 input: nil,
                 deps: nil,
                 provenance: nil
               )

      assert reduce.collection == []
      assert reduce.initial == initial
      assert reduce.input == %{}
      assert reduce.deps == []
      assert reduce.provenance == %{}
    end

    test "rejects malformed configurations with exact paths" do
      base = %{name: :bad, collection: [], initial: %{}, action: Add}

      cases = [
        {:not_a_map, "reduce configuration must be a map", []},
        {Map.delete(base, :name), "reduce name must be a non-empty string or atom", [:name]},
        {Map.delete(base, :collection), "reduce collection is required", [:collection]},
        {Map.delete(base, :initial), "reduce initial is required", [:initial]},
        {%{base | initial: [1 | :tail]}, "reduce initial must be a proper list", [:initial]},
        {%{base | action: "bad"}, "reduce target must be a module atom", [:action]},
        {Map.put(base, :deps, :bad), "reduce deps must be a list", [:deps]},
        {Map.put(base, :deps, [:ok | :tail]), "reduce deps must be a proper list", [:deps]},
        {Map.put(base, :deps, [:ok, nil]), "reduce deps must be a list of step names", [:deps]},
        {Map.put(base, :provenance, :bad), "reduce provenance must be a map", [:provenance]},
        {Map.put(base, :unexpected, true), "unknown reduce configuration key: :unexpected",
         [:unexpected]}
      ]

      for {attrs, expected_message, expected_path} <- cases do
        assert {:error,
                %InvalidInputError{message: ^expected_message, details: %{path: ^expected_path}}} =
                 Reduce.new(attrs)
      end
    end

    test "enforces separate collection, initial, and target-input scopes" do
      for {field, ref} <- [collection: Ref.item_index(), initial: Ref.accumulator()] do
        attrs = %{name: :bad, collection: [], initial: %{}, action: Add} |> Map.put(field, ref)

        assert {:error, %InvalidInputError{message: message, details: details}} =
                 Reduce.new(attrs)

        assert message == "flow expression contains a scoped ref outside its valid scope"
        assert details.path == [field]
        assert details.ref_type == ref.type

        assert details.scope ==
                 if(field == :collection, do: :reduce_collection, else: :reduce_initial)
      end

      assert {:ok, reduce} =
               Reduce.new(
                 name: :valid,
                 collection: [],
                 initial: %{},
                 action: Add,
                 input: %{
                   nested: [Ref.item(), Ref.item_index(), Ref.item_id(), Ref.accumulator()]
                 }
               )

      assert Reduce.result_deps(reduce) == []
    end

    test "revalidates improper structs" do
      valid = Reduce.new!(name: :valid, collection: [], initial: %{}, action: Add)

      assert {:error, %InvalidInputError{message: "reduce deps must be a proper list"}} =
               Reduce.new(%{valid | deps: [:load | :tail]})
    end
  end

  test "preflights a target without invoking it" do
    assert :ok ==
             Reduce.new!(name: :valid, collection: [], initial: %{}, action: Add)
             |> Reduce.check()

    assert {:error, %InvalidInputError{message: message, details: details}} =
             Reduce.new!(name: :bad, collection: [], initial: %{}, action: MissingRun)
             |> Reduce.check()

    assert message =~ "module is not a valid Jido action"
    assert details.reduce == "bad"
    assert details.target == MissingRun
  end

  test "accepts a marked nested Flow target" do
    target = unique_module("ReduceNestedFlow")

    create_module(
      target,
      quote do
        use Jido.Flow, name: "reduce_nested_flow"

        flow do
          step("add",
            action: unquote(Add),
            params: %{value: input(:value), amount: 1}
          )
        end
      end
    )

    assert :ok =
             Reduce.new!(name: :nested, collection: [], initial: 0, action: target)
             |> Reduce.check()
  end
end
