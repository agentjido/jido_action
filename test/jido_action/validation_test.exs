defmodule Jido.Action.ValidationTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Action.Validation

  defmodule Params do
    @moduledoc false
    defstruct [:value]
  end

  describe "open_validate/3" do
    test "validates whole values for non-object Zoi schemas" do
      assert {:ok, 3} = Validation.open_validate(Zoi.integer(), 3, %{context: "Validation"})
    end

    test "keeps Zoi parsing behavior for map and struct schemas" do
      generic_map = Zoi.map(Zoi.string(), Zoi.integer())

      assert {:error, %Jido.Action.Error.InvalidInputError{}} =
               Validation.open_validate(generic_map, %{"value" => "bad"}, %{})

      coerced_object = Zoi.object(%{value: Zoi.integer()}, coerce: true)

      assert {:ok, %{"extra" => 2, value: 1}} =
               Validation.open_validate(coerced_object, %{"value" => 1, "extra" => 2}, %{})

      string_object = Zoi.object(%{"value" => Zoi.integer()})

      assert {:ok, %{"value" => 1}} =
               Validation.open_validate(string_object, %{"value" => 1}, %{})

      struct_schema = Zoi.struct(Params, %{value: Zoi.integer()})

      assert {:ok, %{value: 1}} =
               Validation.open_validate(struct_schema, %Params{value: 1}, %{})
    end
  end
end
