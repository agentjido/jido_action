defmodule Jido.Action.ToolTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Action.Tool
  alias JidoTest.TestActions

  @moduletag :capture_log

  describe "to_tool/1" do
    test "converts a Jido Exec to a tool representation" do
      tool = Tool.to_tool(TestActions.BasicAction)

      assert tool.name == "basic_action"
      assert tool.description == "A basic action for testing"
      assert is_function(tool.function, 2)
      assert is_map(tool.parameters_schema)
    end

    test "generates correct parameters schema" do
      tool = Tool.to_tool(TestActions.BasicAction)

      assert tool.parameters_schema == %{
               "type" => "object",
               "properties" => %{
                 "value" => %{
                   "type" => "integer",
                   "description" => "No description provided."
                 }
               },
               "required" => ["value"]
             }
    end
  end

  describe "to_tool/2 strict mode" do
    test "to_tool/1 remains legacy non-strict by default" do
      tool = Tool.to_tool(TestActions.BasicAction)
      refute Map.has_key?(tool.parameters_schema, "additionalProperties")
    end

    test "applies strict additionalProperties recursively when enabled" do
      tool = Tool.to_tool(TestActions.SchemaAction, strict: true)

      assert tool.parameters_schema["additionalProperties"] == false
      assert tool.parameters_schema["properties"]["map"]["additionalProperties"] == false
    end

    test "supports explicit strict false override" do
      tool = Tool.to_tool(TestActions.BasicAction, strict: false)
      refute Map.has_key?(tool.parameters_schema, "additionalProperties")
    end

    test "Action module to_tool/0 defaults to strict schemas" do
      tool = TestActions.BasicAction.to_tool()
      assert tool.parameters_schema["additionalProperties"] == false
    end
  end

  describe "execute_action/3" do
    # test "executes the action and returns JSON-encoded result" do
    #   params = %{"value" => 42}
    #   context = %{}

    #   assert {:ok, result} = Tool.execute_action(TestActions.BasicAction, params, context)
    #   assert Jason.decode!(result) == %{"value" => 42}
    # end

    test "returns JSON-encoded error on failure" do
      params = %{"invalid" => "params"}
      context = %{}

      assert {:error, error} = Tool.execute_action(TestActions.BasicAction, params, context)
      assert {:ok, %{"error" => _}} = Jason.decode(error)
    end

    test "sanitizes successful structured results before JSON encoding" do
      defmodule StructuredResultAction do
        use Jido.Action,
          name: "structured_result_action",
          description: "Returns a structured result"

        defmodule Result do
          defstruct [:state, :meta]
        end

        def run(_params, _context) do
          {:ok, %Result{state: :done, meta: {:ok, 1}}}
        end
      end

      assert {:ok, result} = Tool.execute_action(StructuredResultAction, %{}, %{})
      assert {:ok, decoded} = Jason.decode(result)
      assert decoded["__struct__"] =~ "StructuredResultAction.Result"
      assert decoded["state"] == "done"
      assert decoded["meta"] == ["ok", 1]
    end

    test "returns JSON-encoded error when exception inspection is unsafe" do
      defmodule UninspectableErrorAction do
        use Jido.Action,
          name: "uninspectable_error_action",
          description: "Returns an uninspectable action error"

        def run(_params, _context) do
          {:error,
           Jido.Action.Error.execution_error(%JidoTest.Support.RaisingInspectStruct{value: 1})}
        end
      end

      assert {:error, error} = Tool.execute_action(UninspectableErrorAction, %{}, %{})
      assert {:ok, %{"error" => message}} = Jason.decode(error)
      assert message =~ "RaisingInspectStruct"
    end
  end

  describe "convert_params_using_schema/2" do
    test "converts string parameters to correct types based on schema" do
      params = %{
        "integer" => "42",
        "float" => "3.14",
        "string" => "hello",
        "unspecified" => "value"
      }

      schema = [
        integer: [type: :integer],
        float: [type: :float],
        string: [type: :string]
      ]

      result = Tool.convert_params_using_schema(params, schema)

      assert result == %{
               "unspecified" => "value",
               integer: 42,
               float: 3.14,
               string: "hello"
             }
    end

    test "handles invalid number strings" do
      params = %{
        "integer" => "not_a_number",
        "float" => "invalid"
      }

      schema = [
        integer: [type: :integer],
        float: [type: :float]
      ]

      result = Tool.convert_params_using_schema(params, schema)

      assert result == %{
               integer: "not_a_number",
               float: "invalid"
             }
    end

    test "preserves parameters not in schema (open validation semantics)" do
      params = %{
        "in_schema" => "42",
        "not_in_schema" => "value"
      }

      schema = [
        in_schema: [type: :integer]
      ]

      result = Tool.convert_params_using_schema(params, schema)

      assert result == %{"not_in_schema" => "value", in_schema: 42}
    end

    test "accepts atom keys in input params" do
      params = %{integer: "42"}
      schema = [integer: [type: :integer]]

      assert Tool.convert_params_using_schema(params, schema) == %{integer: 42}
    end

    test "prefers atom keys over string keys when both provided" do
      params = %{"integer" => "42", integer: "41"}
      schema = [integer: [type: :integer]]

      assert Tool.convert_params_using_schema(params, schema) == %{integer: 41}
    end

    test "preserves unknown atom keys" do
      params = %{in_schema: "1", extra: "x"}
      schema = [in_schema: [type: :integer]]

      assert Tool.convert_params_using_schema(params, schema) == %{in_schema: 1, extra: "x"}
    end

    test "coerces integer to float when schema expects float" do
      params = %{"temperature" => 20}
      schema = [temperature: [type: :float]]

      result = Tool.convert_params_using_schema(params, schema)
      assert result == %{temperature: 20.0}
      assert is_float(result.temperature)
    end

    test "preserves float values when schema expects float" do
      params = %{"temperature" => 20.5}
      schema = [temperature: [type: :float]]

      result = Tool.convert_params_using_schema(params, schema)
      assert result == %{temperature: 20.5}
    end

    test "parses string to float and does not double-coerce" do
      params = %{"temperature" => "20"}
      schema = [temperature: [type: :float]]

      result = Tool.convert_params_using_schema(params, schema)
      assert result == %{temperature: 20.0}
      assert is_float(result.temperature)
    end

    test "preserves nested map payloads for NimbleOptions map fields" do
      params = %{
        "payload" => %{"nested" => %{"value" => "raw"}},
        "count" => "2"
      }

      schema = [
        payload: [type: :map],
        count: [type: :integer]
      ]

      result = Tool.convert_params_using_schema(params, schema)

      assert result == %{
               payload: %{"nested" => %{"value" => "raw"}},
               count: 2
             }
    end
  end

  describe "build_parameters_schema/1" do
    test "builds correct schema from action schema" do
      schema = TestActions.SchemaAction.schema()
      result = Tool.build_parameters_schema(schema)

      assert result == %{
               "type" => "object",
               "properties" => %{
                 "string" => %{"type" => "string", "description" => "No description provided."},
                 "integer" => %{"type" => "integer", "description" => "No description provided."},
                 "atom" => %{"type" => "string", "description" => "No description provided."},
                 "boolean" => %{"type" => "boolean", "description" => "No description provided."},
                 "list" => %{
                   "type" => "array",
                   "items" => %{"type" => "string"},
                   "description" => "No description provided."
                 },
                 "keyword_list" => %{
                   "type" => "object",
                   "description" => "No description provided."
                 },
                 "map" => %{"type" => "object", "description" => "No description provided."},
                 "custom" => %{"type" => "string", "description" => "No description provided."}
               },
               "required" => []
             }
    end

    test "build_parameters_schema/2 applies strict mode recursively" do
      schema = TestActions.SchemaAction.schema()
      result = Tool.build_parameters_schema(schema, strict: true)

      assert result["additionalProperties"] == false
      assert result["properties"]["map"]["additionalProperties"] == false
    end

    test "build_parameters_schema/2 with strict false preserves legacy output" do
      schema = TestActions.SchemaAction.schema()
      legacy = Tool.build_parameters_schema(schema)
      strict_false = Tool.build_parameters_schema(schema, strict: false)

      assert strict_false == legacy
    end
  end

  # Note: parameter_to_json_schema/1 and nimble_type_to_json_schema_type/1 are now
  # private implementation details in Jido.Action.Schema. The public API is
  # Jido.Action.Schema.to_json_schema/1 and /2 which are tested via build_parameters_schema/1 and /2
end
