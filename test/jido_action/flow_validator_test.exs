defmodule JidoTest.FlowValidatorTest do
  use ExUnit.Case, async: true

  alias Jido.Flow.Validator

  describe "validate_component_name/1" do
    test "accepts non-nil atoms" do
      assert :ok = Validator.validate_component_name(:step_name)
    end

    test "rejects nil, strings, and unsupported values" do
      assert {:error, "cannot be nil"} = Validator.validate_component_name(nil)
      assert {:error, "must be an atom"} = Validator.validate_component_name("")
      assert {:error, "must be an atom"} = Validator.validate_component_name("step_name")
      assert {:error, "must be an atom"} = Validator.validate_component_name(123)
    end
  end

  describe "validate_optional_component_name/1" do
    test "accepts nil and delegates non-nil names" do
      assert :ok = Validator.validate_optional_component_name(nil)
      assert :ok = Validator.validate_optional_component_name(:step_name)
      assert {:error, "must be an atom"} = Validator.validate_optional_component_name("")
    end
  end
end
