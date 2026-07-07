defmodule Jido.Flow.RefTest do
  use ExUnit.Case, async: true

  alias Jido.Flow.Ref

  describe "constructors" do
    test "normalizes scalar and nil paths" do
      assert Ref.input(:value).path == [:value]
      assert Ref.input("value").path == ["value"]
      assert Ref.input(0).path == [0]
      assert Ref.input(nil).path == []
      assert Ref.context(:trace_id).path == [:trace_id]
      assert Ref.context(nil).path == []
      assert Ref.result(:step, nil).path == []
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
    end
  end
end
