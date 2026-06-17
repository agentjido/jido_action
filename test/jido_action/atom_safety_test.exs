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

  alias Jido.Exec
  alias JidoTest.TestActions.EchoAction
  alias JidoTest.TestActions.SchemaAction

  @moduletag :atom_safety

  setup_all do
    # Warm up modules and schemas so their one-time atom creation
    # is not counted in the per-test measurements.
    _ = Exec.run(EchoAction, %{"warmup" => "1"})
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
      {:ok, %{params: normalized}} = Exec.run(EchoAction, params)

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

      {:ok, %{params: normalized}} = Exec.run(EchoAction, params)

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

      {:ok, %{params: normalized}} = Exec.run(EchoAction, params)

      # String keys should remain as strings
      assert Map.has_key?(normalized, "user_input_key")
      assert Map.has_key?(normalized, "another_user_key")
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
      {:ok, %{params: result}} = Exec.run(EchoAction, malicious_params)

      atom_count_after = :erlang.system_info(:atom_count)

      # Should not create 10,000 atoms - allow for framework/library overhead
      # The key property is "far less than 10,000" - we're detecting per-key leaks
      assert atom_count_after - atom_count_before < 500,
             "Potential atom leak: #{atom_count_after - atom_count_before} atoms created from 10,000 string keys"

      # Result should still be a map with string keys
      assert is_map(result)
      assert map_size(result) == 10_000
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
