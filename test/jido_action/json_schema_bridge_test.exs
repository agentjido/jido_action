defmodule Jido.Action.JsonSchemaBridgeTest do
  use ExUnit.Case, async: true

  alias Jido.Action.Schema.JsonSchemaBridge
  alias Jido.Action.Tool

  @schema %{
    "type" => "object",
    "properties" => %{
      "query" => %{"type" => "string"},
      "limit" => %{"type" => "integer"},
      "filters" => %{
        "type" => "object",
        "properties" => %{
          "tags" => %{
            "type" => "array",
            "items" => %{"type" => "string"}
          }
        }
      }
    },
    "required" => ["query"]
  }
  @flat_schema %{
    "type" => "object",
    "properties" => %{
      "query" => %{"type" => "string"},
      "limit" => %{"type" => "integer"}
    },
    "required" => ["query"]
  }

  describe "to_zoi/1" do
    test "builds a Zoi schema for supported JSON Schema subsets" do
      assert {:ok, zoi_schema} = JsonSchemaBridge.to_zoi(@schema)

      params = %{
        "query" => "elixir",
        "limit" => 10,
        "filters" => %{"tags" => ["tooling"]},
        "extra" => "preserved"
      }

      assert {:ok, parsed} = Zoi.parse(zoi_schema, params, coerce: true)
      assert parsed.query == "elixir"
      assert parsed.limit == 10
      assert parsed.filters["tags"] == ["tooling"]
      assert parsed["extra"] == "preserved"
    end

    test "falls back on unsupported keywords" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "query" => %{"type" => "string", "minLength" => 3}
        }
      }

      assert {:fallback, {:unsupported_keyword, "minLength"}} = JsonSchemaBridge.to_zoi(schema)
    end
  end

  describe "convert_params/2 parity" do
    test "matches legacy conversion for representative JSON Schema input" do
      params = %{
        "query" => "elixir",
        "limit" => 5,
        "extra" => "preserved"
      }

      legacy = Tool.convert_params_using_schema(params, @flat_schema)
      assert {:ok, bridged} = JsonSchemaBridge.convert_params(params, @flat_schema)
      assert bridged == legacy
    end

    test "preserves atom precedence when both atom and string keys are present" do
      params = %{"query" => "string value", "limit" => 7, query: "atom value"}

      legacy = Tool.convert_params_using_schema(params, @flat_schema)
      assert {:ok, bridged} = JsonSchemaBridge.convert_params(params, @flat_schema)
      assert bridged == legacy
      assert bridged.query == "atom value"
    end

    test "falls back instead of raising for unsupported schemas" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "query" => %{"type" => "string", "pattern" => "^[a-z]+$"}
        }
      }

      assert {:fallback, {:unsupported_keyword, "pattern"}} =
               JsonSchemaBridge.convert_params(%{"query" => "ok"}, schema)
    end

    test "matches legacy conversion for nested object payloads" do
      params = %{
        "query" => "elixir",
        "filters" => %{
          "tags" => ["a", "b"],
          "extra_nested" => "keep"
        },
        "extra" => "preserved"
      }

      legacy = Tool.convert_params_using_schema(params, @schema)
      assert {:ok, bridged} = JsonSchemaBridge.convert_params(params, @schema)
      assert bridged == legacy
      assert bridged.filters == %{"tags" => ["a", "b"], "extra_nested" => "keep"}
    end
  end
end
