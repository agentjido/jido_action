defmodule Jido.Flow.RefTest do
  use ExUnit.Case, async: true

  alias Jido.Flow.Ref
  alias Jido.Action.Error.InvalidInputError

  describe "constructors" do
    test "normalizes scalar and nil paths" do
      assert Ref.input(:value).path == [:value]
      assert Ref.input("value").path == ["value"]
      assert Ref.input(0).path == [0]
      assert Ref.input(nil).path == []
      assert Ref.context(:trace_id).path == [:trace_id]
      assert Ref.context(nil).path == []
      assert Ref.result(:step, nil).path == []
      assert Ref.item(nil).path == []
      assert Ref.item(:value).path == [:value]
      assert Ref.item_index().path == []
      assert Ref.item_id().path == []
      assert Ref.accumulator([:value, 0]).path == [:value, 0]
    end

    test "normalizes result node names to strings" do
      assert Ref.result(:add_one) == Ref.result("add_one")
      assert Ref.result(:add_one).node == "add_one"
    end

    test "preserves list paths and literal values in semantic maps" do
      assert Ref.to_map(Ref.input([:payload, "items", 0])) == %{
               type: :input,
               path: [:payload, "items", 0]
             }

      assert Ref.to_map(Ref.result(:load, [:value])) == %{
               type: :result,
               node: "load",
               path: [:value]
             }

      assert Ref.to_map(Ref.context([:tenant, "id", 0])) == %{
               type: :context,
               path: [:tenant, "id", 0]
             }

      assert Ref.to_map(Ref.value(%{amount: 2})) == %{
               type: :value,
               value: %{amount: 2}
             }

      assert Ref.to_map(Ref.item(:value)) == %{type: :item, path: [:value]}
      assert Ref.to_map(Ref.item_index()) == %{type: :item_index}
      assert Ref.to_map(Ref.item_id()) == %{type: :item_id}

      assert Ref.to_map(Ref.accumulator(:value)) == %{
               type: :accumulator,
               path: [:value]
             }
    end
  end

  describe "validate/1" do
    test "rejects improper path lists" do
      ref = Ref.input([:payload | :tail])

      assert {:error, %InvalidInputError{message: "invalid flow ref", details: details}} =
               Ref.validate(ref)

      assert details.ref == ref
      assert details.reason == :path
      assert details.segment == :tail
    end

    test "enforces explicit local-ref scopes" do
      map_locals = [Ref.item(), Ref.item_index(), Ref.item_id()]

      for ref <- map_locals do
        assert :ok = Ref.validate(ref, :map_input)
        assert :ok = Ref.validate(ref, :reduce_input)

        for scope <- [:flow, :map_collection, :reduce_collection, :reduce_initial] do
          assert {:error,
                  %InvalidInputError{
                    message: "invalid flow ref",
                    details: %{reason: :scope, type: type, scope: ^scope}
                  }} = Ref.validate(ref, scope)

          assert type == ref.type
        end
      end

      assert :ok = Ref.validate(Ref.accumulator(), :reduce_input)

      for scope <- [:flow, :map_collection, :map_input, :reduce_collection, :reduce_initial] do
        assert {:error,
                %InvalidInputError{
                  details: %{reason: :scope, type: :accumulator, scope: ^scope}
                }} = Ref.validate(Ref.accumulator(), scope)
      end
    end

    test "rejects paths on scalar local refs" do
      for type <- [:item_index, :item_id] do
        ref = %Ref{type: type, path: [:bad], node: nil, value: nil}

        assert {:error, %InvalidInputError{details: %{reason: :shape, type: ^type}}} =
                 Ref.validate(ref, :reduce_input)
      end
    end
  end
end
