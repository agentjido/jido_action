defmodule Jido.Action.SchemaJsonTest do
  use ExUnit.Case, async: true

  alias Jido.Action.Schema

  describe "to_json_schema/1 - empty schema" do
    test "empty schema returns valid JSON Schema object" do
      result = Schema.to_json_schema([])

      assert result == %{"type" => "object", "properties" => %{}, "required" => []}
    end
  end

  describe "to_json_schema/1 - list types with items" do
    test "list of strings includes items typing" do
      schema = [tags: [type: {:list, :string}]]
      result = Schema.to_json_schema(schema)

      assert result["properties"]["tags"] == %{
               "type" => "array",
               "items" => %{"type" => "string"},
               "description" => "No description provided."
             }
    end

    test "list of integers includes items typing" do
      schema = [ids: [type: {:list, :integer}]]
      result = Schema.to_json_schema(schema)

      assert result["properties"]["ids"]["type"] == "array"
      assert result["properties"]["ids"]["items"] == %{"type" => "integer"}
    end

    test "nested list includes nested items typing" do
      schema = [matrix: [type: {:list, {:list, :integer}}]]
      result = Schema.to_json_schema(schema)

      assert result["properties"]["matrix"]["type"] == "array"

      assert result["properties"]["matrix"]["items"] == %{
               "type" => "array",
               "items" => %{"type" => "integer"}
             }
    end
  end

  describe "to_json_schema/1 - enum via {:in, choices}" do
    test "atom enum generates string enum schema" do
      schema = [status: [type: {:in, [:pending, :active, :done]}]]
      result = Schema.to_json_schema(schema)

      assert result["properties"]["status"]["type"] == "string"
      assert result["properties"]["status"]["enum"] == ["pending", "active", "done"]
    end

    test "string enum generates string enum schema" do
      schema = [mode: [type: {:in, ["fast", "slow"]}]]
      result = Schema.to_json_schema(schema)

      assert result["properties"]["mode"]["type"] == "string"
      assert result["properties"]["mode"]["enum"] == ["fast", "slow"]
    end

    test "integer enum generates integer enum schema" do
      schema = [priority: [type: {:in, [1, 2, 3]}]]
      result = Schema.to_json_schema(schema)

      assert result["properties"]["priority"]["type"] == "integer"
      assert result["properties"]["priority"]["enum"] == [1, 2, 3]
    end

    test "boolean enum generates boolean enum schema" do
      schema = [enabled: [type: {:in, [true, false]}]]
      result = Schema.to_json_schema(schema)

      assert result["properties"]["enabled"]["type"] == "boolean"
      assert result["properties"]["enabled"]["enum"] == [true, false]
    end
  end

  describe "to_json_schema/1 - numeric subtypes" do
    test "non_neg_integer maps correctly" do
      schema = [count: [type: :non_neg_integer]]
      result = Schema.to_json_schema(schema)

      assert result["properties"]["count"]["type"] == "integer"
      assert result["properties"]["count"]["minimum"] == 0
    end

    test "pos_integer maps correctly" do
      schema = [page: [type: :pos_integer]]
      result = Schema.to_json_schema(schema)

      assert result["properties"]["page"]["type"] == "integer"
      assert result["properties"]["page"]["minimum"] == 1
    end

    test ":timeout maps to integer or infinity" do
      schema = [timeout: [type: :timeout]]
      result = Schema.to_json_schema(schema)

      assert %{"oneOf" => one_of} = result["properties"]["timeout"]
      assert Enum.any?(one_of, &(&1["type"] == "integer"))
      assert Enum.any?(one_of, &(&1["enum"] == ["infinity"]))
    end
  end

  describe "to_json_schema/1 - number type" do
    test ":number maps to JSON number type (not integer)" do
      schema = [value: [type: :number]]
      result = Schema.to_json_schema(schema)

      assert result["properties"]["value"]["type"] == "number"
    end
  end

  describe "to_json_schema/2 - strict mode" do
    test "adds additionalProperties false to top-level object when strict" do
      schema = [value: [type: :integer]]
      result = Schema.to_json_schema(schema, strict: true)

      assert result["additionalProperties"] == false
    end

    test "recursively sets additionalProperties false for nested map properties" do
      schema = [config: [type: :map]]
      result = Schema.to_json_schema(schema, strict: true)

      assert result["additionalProperties"] == false
      assert result["properties"]["config"]["additionalProperties"] == false
    end

    test "recursively sets additionalProperties false for objects in arrays" do
      schema = [items: [type: {:list, :map}]]
      result = Schema.to_json_schema(schema, strict: true)

      assert result["additionalProperties"] == false
      assert result["properties"]["items"]["items"]["additionalProperties"] == false
    end

    test "strict false preserves legacy schema output" do
      schema = [config: [type: :map]]
      legacy = Schema.to_json_schema(schema)
      strict_false = Schema.to_json_schema(schema, strict: false)

      assert strict_false == legacy
      refute Map.has_key?(legacy, "additionalProperties")
      refute Map.has_key?(legacy["properties"]["config"], "additionalProperties")
    end
  end
end
