defmodule Jido.Action.JsonSchemaMapTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Action
  alias Jido.Action.{Schema, Tool}
  alias Jido.Exec

  @moduletag :capture_log

  @test_schema %{
    "type" => "object",
    "properties" => %{
      "query" => %{"type" => "string", "description" => "Search query"},
      "limit" => %{"type" => "integer", "description" => "Max results"}
    },
    "required" => ["query"],
    "additionalProperties" => false
  }

  describe "Schema.schema_type/1" do
    test "recognizes JSON Schema maps" do
      assert Schema.schema_type(@test_schema) == :json_schema
    end

    test "rejects maps without properties key" do
      assert Schema.schema_type(%{"type" => "object"}) == :unknown
    end

    test "rejects maps with non-object type" do
      schema = %{"type" => "string", "properties" => %{}}
      assert Schema.schema_type(schema) == :unknown
    end
  end

  describe "Schema.validate/2 with JSON Schema maps" do
    test "passes data through without modification" do
      data = %{query: "elixir", limit: 10}
      assert {:ok, ^data} = Schema.validate(@test_schema, data)
    end

    test "does not reject unknown keys" do
      data = %{query: "elixir", extra: "value"}
      assert {:ok, ^data} = Schema.validate(@test_schema, data)
    end

    test "does not reject missing required keys" do
      data = %{limit: 10}
      assert {:ok, ^data} = Schema.validate(@test_schema, data)
    end
  end

  describe "Schema.known_keys/1 with JSON Schema maps" do
    test "extracts atom keys from properties" do
      keys = Schema.known_keys(@test_schema)
      assert Enum.sort(keys) == [:limit, :query]
    end

    test "returns empty list for empty properties" do
      schema = %{"type" => "object", "properties" => %{}}
      assert Schema.known_keys(schema) == []
    end
  end

  describe "Schema.to_json_schema/1 with JSON Schema maps" do
    test "returns the map unchanged" do
      assert Schema.to_json_schema(@test_schema) == @test_schema
    end

    test "strict mode still applies additionalProperties" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "nested" => %{
            "type" => "object",
            "properties" => %{"a" => %{"type" => "string"}}
          }
        }
      }

      result = Schema.to_json_schema(schema, strict: true)
      assert result["additionalProperties"] == false
      assert result["properties"]["nested"]["additionalProperties"] == false
    end
  end

  describe "Schema.validate_config_schema/1 with JSON Schema maps" do
    test "accepts valid JSON Schema maps" do
      assert :ok = Schema.validate_config_schema(@test_schema)
    end

    test "rejects plain maps without type/properties" do
      assert {:error, _} = Schema.validate_config_schema(%{"foo" => "bar"})
    end
  end

  describe "Tool.convert_params_using_schema/2 with JSON Schema maps" do
    test "converts string keys to atom keys based on properties" do
      params = %{"query" => "elixir", "limit" => 10}
      result = Tool.convert_params_using_schema(params, @test_schema)
      assert result == %{query: "elixir", limit: 10}
    end

    test "preserves unknown string keys" do
      params = %{"query" => "elixir", "extra" => "value"}
      result = Tool.convert_params_using_schema(params, @test_schema)
      assert result[:query] == "elixir"
      assert result["extra"] == "value"
    end

    test "preserves atom keys in input" do
      params = %{query: "elixir", limit: 10}
      result = Tool.convert_params_using_schema(params, @test_schema)
      assert result == %{query: "elixir", limit: 10}
    end
  end

  describe "Action with JSON Schema map via use Jido.Action" do
    defmodule SearchAction do
      use Action,
        name: "search",
        description: "Search for items",
        schema: %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string", "description" => "Search query"},
            "limit" => %{"type" => "integer", "description" => "Max results"}
          },
          "required" => ["query"],
          "additionalProperties" => false
        }

      @impl true
      def run(params, _context) do
        {:ok, %{query: params[:query] || params["query"], count: 0}}
      end
    end

    test "action compiles and exposes schema" do
      assert SearchAction.name() == "search"
      assert SearchAction.description() == "Search for items"
      assert %{"type" => "object"} = SearchAction.schema()
    end

    test "runs with valid params" do
      assert {:ok, result} = Exec.run(SearchAction, %{query: "elixir"}, %{})
      assert result.query == "elixir"
      assert result.count == 0
    end

    test "runs with string-keyed params" do
      assert {:ok, result} = Exec.run(SearchAction, %{"query" => "elixir"}, %{})
      assert result.query == "elixir"
    end

    test "to_tool produces correct parameters_schema" do
      tool = Tool.to_tool(SearchAction)
      assert tool.name == "search"
      assert tool.parameters_schema["properties"]["query"]["type"] == "string"
      assert tool.parameters_schema["required"] == ["query"]
    end

    test "module-level to_tool/0 works" do
      tool = SearchAction.to_tool()
      assert tool.parameters_schema["properties"]["query"]["description"] == "Search query"
    end
  end
end
