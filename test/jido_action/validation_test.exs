defmodule Jido.Action.ValidationTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Action.Validation

  describe "open_validate/3" do
    test "validates whole values for non-object Zoi schemas" do
      assert {:ok, 3} = Validation.open_validate(Zoi.integer(), 3, %{context: "Validation"})
    end
  end
end
