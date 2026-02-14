defmodule Jido.Action.SchemaTest do
  use ExUnit.Case, async: true

  alias Jido.Action.Error
  alias Jido.Action.Schema

  describe "validate/2" do
    test "returns structured error for unsupported schema types" do
      assert {:error, %Error.InvalidInputError{} = error} = Schema.validate(:unsupported, %{})
      assert error.message == "Unsupported schema type"
      assert error.details[:reason] == :unsupported_schema_type
      assert error.details[:schema] == ":unsupported"
    end
  end

  describe "format_error/3" do
    test "passes through existing exceptions" do
      error =
        Error.validation_error("Already normalized", %{
          reason: :already_normalized
        })

      assert ^error = Schema.format_error(error, "Action", __MODULE__)
    end
  end
end
