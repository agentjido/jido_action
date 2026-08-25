defmodule JidoActionTest.Flow.ResourceBudgetTest do
  use ExUnit.Case, async: true

  alias Jido.Action.Error.InvalidInputError
  alias Jido.Flow.ResourceBudget

  @max_depth 64
  @max_terms 100_000
  @max_binary_bytes 1_048_576
  @max_width 10_000

  describe "validate/1" do
    test "accepts each exact stored-map limit" do
      assert :ok = ResourceBudget.validate(nested_tuple(@max_depth + 1))
      assert :ok = ResourceBudget.validate(term_slots(@max_terms))
      assert :ok = ResourceBudget.validate(:binary.copy("x", @max_binary_bytes))
      assert :ok = ResourceBudget.validate(List.duplicate(0, @max_width))
    end

    test "rejects each stored-term limit plus one with exact bounded details" do
      cases = [
        {nested_tuple(@max_depth + 2), :nesting_depth, @max_depth, @max_depth + 1,
         List.duplicate(0, @max_depth + 1)},
        {term_slots(@max_terms + 1), :term_count, @max_terms, @max_terms + 1,
         [9, @max_width - 11]},
        {:binary.copy("x", @max_binary_bytes + 1), :binary_bytes, @max_binary_bytes,
         @max_binary_bytes + 1, []},
        {List.duplicate(0, @max_width + 1), :collection_width, @max_width, @max_width + 1, []}
      ]

      for {term, resource, limit, actual, path} <- cases do
        assert {:error,
                %InvalidInputError{
                  message: "stored flow map exceeds resource limit",
                  details: details
                }} = ResourceBudget.validate(term)

        assert details == %{
                 profile: :stored,
                 resource: resource,
                 limit: limit,
                 actual: actual,
                 path: path
               }

        refute inspect(details) =~ String.duplicate("x", 256)
      end
    end

    test "accounts for aggregate binaries and uses deterministic map-entry paths" do
      term = %{"a" => :binary.copy("a", 600_000), "b" => :binary.copy("b", 600_000)}

      assert {:error, %InvalidInputError{details: details}} =
               ResourceBudget.validate(term)

      assert details.resource == :binary_bytes
      assert details.actual == 1_200_002
      assert details.path == [{:map_value, 1}]
      refute Map.has_key?(details, :value)
    end

    test "does not echo large binary or compound map keys in errors" do
      large_key = :binary.copy("k", @max_binary_bytes + 1)

      for term <- [%{large_key => true}, %{{large_key, :suffix} => true}] do
        assert {:error, %InvalidInputError{details: details} = error} =
                 ResourceBudget.validate(term)

        assert details.resource == :binary_bytes

        assert Enum.all?(details.path, fn
                 index when is_integer(index) -> true
                 {kind, index} when kind in [:map_key, :map_value] and is_integer(index) -> true
               end)

        refute inspect(details) =~ String.duplicate("k", 256)
        refute Exception.message(error) =~ String.duplicate("k", 256)
      end
    end

    test "checks term slots, binary bytes, depth, then width for each work item" do
      over_width = List.duplicate(:binary.copy("x", 256), @max_width + 1)

      assert {:error, %InvalidInputError{details: details}} =
               ResourceBudget.validate(over_width)

      assert details.resource == :collection_width
      assert details.path == []
    end

    test "handles maps, lists, tuples, and improper tails without recursive traversal" do
      term = {%{"a" => [1, 2]}, [3 | :tail]}

      assert :ok = ResourceBudget.validate(term)
    end

    test "accepts nested structs that do not implement Enumerable" do
      term = %{metadata: %{uri: URI.parse("https://example.com/flow")}}

      assert :ok = ResourceBudget.validate(term)
    end
  end

  defp nested_tuple(container_count) do
    Enum.reduce(1..container_count, :leaf, fn _, value -> {value} end)
  end

  defp term_slots(total) do
    scalar_count = total - 11
    full_lists = div(scalar_count, @max_width)
    remainder = rem(scalar_count, @max_width)

    lists =
      List.duplicate(List.duplicate(0, @max_width), full_lists) ++
        [List.duplicate(0, remainder)]

    lists ++ List.duplicate([], 10 - length(lists))
  end
end
