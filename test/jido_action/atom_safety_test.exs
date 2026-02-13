defmodule Jido.Action.AtomSafetyTest do
  @moduledoc """
  Tests to verify no atom table exhaustion vulnerabilities.

  This test suite ensures that user input cannot cause unbounded atom creation,
  which could lead to atom table exhaustion DoS attacks.

  Note: async: false is required because :erlang.system_info(:atom_count) is a
  global counter. Running async would cause interference from other tests
  creating atoms concurrently.
  """
  use ExUnit.Case, async: false

  alias Jido.Action.Tool
  alias Jido.Exec
  alias JidoTest.TestActions.SchemaAction

  @moduletag :atom_safety

  setup_all do
    # Warm up modules and schemas so their one-time atom creation
    # is not counted in the per-test measurements.
    _ = Exec.__test_normalize_params__(%{"warmup" => "1"})
    _ = Tool.convert_params_using_schema(%{"warmup" => "1"}, warmup: [type: :string])
    schema = Zoi.object(%{warmup: Zoi.string()}, coerce: true)
    _ = Tool.convert_params_using_schema(%{"warmup" => "1"}, schema)
    :ok
  end

  describe "normalize_params atom safety" do
    test "does not create new atoms from string keys" do
      atom_count_before = :erlang.system_info(:atom_count)

      # Create params with 100 random string keys
      params =
        Map.new(1..100, fn i ->
          {"random_key_#{i}_#{:rand.uniform(1_000_000)}", "value_#{i}"}
        end)

      # Normalize should not create atoms
      {:ok, normalized} = Exec.__test_normalize_params__(params)

      atom_count_after = :erlang.system_info(:atom_count)

      # Allow for minimal tolerance due to test framework internals
      # but should not grow proportionally to number of keys
      assert atom_count_after - atom_count_before < 20,
             "Atom table grew by #{atom_count_after - atom_count_before} atoms from #{map_size(params)} string keys"

      # Verify normalization preserves the data
      assert is_map(normalized)
      assert map_size(normalized) == 100
    end

    test "does not create atoms from keyword lists" do
      # Note: keyword lists already have atom keys
      # Map.new just converts structure, doesn't create new atoms
      atom_count_before = :erlang.system_info(:atom_count)

      # Use pre-existing atoms
      params = [test_key_1: "value1", test_key_2: "value2", test_key_3: "value3"]

      {:ok, normalized} = Exec.__test_normalize_params__(params)

      atom_count_after = :erlang.system_info(:atom_count)

      # Should not create significant new atoms
      assert atom_count_after - atom_count_before < 10
      assert is_map(normalized)
    end

    test "preserves string keys without converting to atoms" do
      params = %{
        "user_input_key" => "value",
        "another_user_key" => "another_value"
      }

      {:ok, normalized} = Exec.__test_normalize_params__(params)

      # String keys should remain as strings
      assert Map.has_key?(normalized, "user_input_key")
      assert Map.has_key?(normalized, "another_user_key")
    end
  end

  describe "Tool.convert_params_using_schema atom safety" do
    test "only converts to known schema atoms and preserves unknown keys as strings" do
      schema = [
        known_param: [type: :string],
        another_param: [type: :integer]
      ]

      atom_count_before = :erlang.system_info(:atom_count)

      # Params with known and unknown keys
      params = %{
        "known_param" => "value1",
        "another_param" => 42,
        "unknown_param_1" => "preserved",
        "unknown_param_2" => "preserved",
        "unknown_param_3" => "preserved"
      }

      result = Tool.convert_params_using_schema(params, schema)

      atom_count_after = :erlang.system_info(:atom_count)

      # Should only create atoms for known schema keys (if not already existing)
      # Not proportional to number of unknown keys
      # Allowing more headroom for test overhead and compilation atoms
      assert atom_count_after - atom_count_before < 100,
             "Created #{atom_count_after - atom_count_before} atoms (expected < 100)"

      # Known keys are converted to atoms, unknown keys remain as strings (open validation)
      atom_keys = result |> Map.keys() |> Enum.filter(&is_atom/1) |> Enum.sort()
      string_keys = result |> Map.keys() |> Enum.filter(&is_binary/1) |> Enum.sort()

      assert atom_keys == [:another_param, :known_param]
      assert string_keys == ["unknown_param_1", "unknown_param_2", "unknown_param_3"]
    end

    test "does not create atoms from arbitrary string keys" do
      schema = [param: [type: :string]]

      atom_count_before = :erlang.system_info(:atom_count)

      # Create params with one valid key and many invalid keys (50 unique keys)
      params =
        Map.new(1..50, fn i ->
          {"malicious_key_#{i}_#{:rand.uniform(1_000_000)}", "preserved"}
        end)
        |> Map.put("param", "valid")

      result = Tool.convert_params_using_schema(params, schema)

      atom_count_after = :erlang.system_info(:atom_count)

      # Should not grow proportionally to number of extra keys
      assert atom_count_after - atom_count_before < 20

      # Schema key should be converted to atom, unknown keys preserved as strings
      atom_keys = result |> Map.keys() |> Enum.filter(&is_atom/1)
      string_keys = result |> Map.keys() |> Enum.filter(&is_binary/1)

      assert atom_keys == [:param]
      assert length(string_keys) == 50
    end
  end

  describe "malicious input scenarios" do
    test "attempt to exhaust atom table with many unique string keys" do
      atom_count_before = :erlang.system_info(:atom_count)

      # Simulate attacker trying to create many unique atoms
      malicious_params =
        Map.new(1..10_000, fn i ->
          {"malicious_key_#{i}_#{:rand.uniform(1_000_000)}", "value"}
        end)

      # Normalize should not create atoms
      {:ok, result} = Exec.__test_normalize_params__(malicious_params)

      atom_count_after = :erlang.system_info(:atom_count)

      # Should not create 10,000 atoms - allow for framework/library overhead
      # The key property is "far less than 10,000" - we're detecting per-key leaks
      assert atom_count_after - atom_count_before < 500,
             "Potential atom leak: #{atom_count_after - atom_count_before} atoms created from 10,000 string keys"

      # Result should still be a map with string keys
      assert is_map(result)
      assert map_size(result) == 10_000
    end

    test "attempt atom exhaustion via Tool.convert_params_using_schema" do
      schema = [legit_param: [type: :string]]

      atom_count_before = :erlang.system_info(:atom_count)

      # Attacker sends many unknown parameters hoping for atom conversion
      attack_params =
        Map.new(1..5_000, fn i ->
          {"attack_vector_#{i}_#{:rand.uniform(1_000_000)}", "malicious"}
        end)
        |> Map.put("legit_param", "legitimate value")

      result = Tool.convert_params_using_schema(attack_params, schema)

      atom_count_after = :erlang.system_info(:atom_count)

      # Should not create thousands of atoms - allow for framework/library overhead
      assert atom_count_after - atom_count_before < 500,
             "Potential atom leak: #{atom_count_after - atom_count_before} atoms created from 5,000 malicious keys"

      # Schema key should be atom, unknown keys preserved as strings (still atom-safe)
      atom_keys = result |> Map.keys() |> Enum.filter(&is_atom/1)
      string_keys = result |> Map.keys() |> Enum.filter(&is_binary/1)

      assert atom_keys == [:legit_param]
      assert length(string_keys) == 5_000
    end

    test "large params map with Zoi schema" do
      # Test with Zoi schema as well
      schema = Zoi.object(%{legit: Zoi.string()}, coerce: true)

      atom_count_before = :erlang.system_info(:atom_count)

      params =
        Map.new(1..1_000, fn i ->
          {"random_#{i}_#{:rand.uniform(1_000_000)}", "value"}
        end)
        |> Map.put("legit", "valid")

      result = Tool.convert_params_using_schema(params, schema)

      atom_count_after = :erlang.system_info(:atom_count)

      assert atom_count_after - atom_count_before < 50,
             "Zoi schema created #{atom_count_after - atom_count_before} atoms"

      # Schema key should be atom, unknown keys preserved as strings
      atom_keys = result |> Map.keys() |> Enum.filter(&is_atom/1)
      string_keys = result |> Map.keys() |> Enum.filter(&is_binary/1)

      assert atom_keys == [:legit]
      assert length(string_keys) == 1_000
    end
  end

  describe "test helper safety audit" do
    test "SchemaAction.validate_custom uses unsafe String.to_atom - KNOWN ISSUE" do
      # This is a KNOWN ISSUE in test helpers
      # Document that this is only for testing and should never be used in production
      atom_count_before = :erlang.system_info(:atom_count)

      # Calling this multiple times with unique strings WILL create atoms
      {:ok, _atom1} = SchemaAction.validate_custom("unique_atom_test_1")
      {:ok, _atom2} = SchemaAction.validate_custom("unique_atom_test_2")
      {:ok, _atom3} = SchemaAction.validate_custom("unique_atom_test_3")

      atom_count_after = :erlang.system_info(:atom_count)

      # This WILL create atoms - it's a test helper limitation
      # Should be documented as UNSAFE for production use
      assert atom_count_after - atom_count_before >= 3,
             "Test helper creates atoms as expected (this is test-only code)"
    end
  end
end
