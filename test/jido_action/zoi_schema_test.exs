defmodule Jido.Action.ZoiSchemaTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Action
  alias Jido.Exec

  @moduletag :capture_log

  describe "Basic Zoi schema validation via Exec" do
    defmodule BasicZoiAction do
      use Action,
        name: "basic_zoi",
        description: "Simple action with Zoi schema",
        schema:
          Zoi.object(%{
            name: Zoi.string(),
            age: Zoi.integer()
          })

      def run(params, _context) do
        {:ok, %{greeting: "Hello #{params.name}, age #{params.age}"}}
      end
    end

    test "validates and runs with valid params" do
      assert {:ok, result} = Exec.run(BasicZoiAction, %{name: "Alice", age: 30}, %{})
      assert result.greeting == "Hello Alice, age 30"
    end

    test "returns validation error for invalid types" do
      assert {:error, error} = Exec.run(BasicZoiAction, %{name: "Bob", age: "invalid"}, %{})
      assert %Action.Error.InvalidInputError{} = error
      assert error.message =~ "age"
    end

    test "returns validation error for missing required fields" do
      assert {:error, error} = Exec.run(BasicZoiAction, %{name: "Charlie"}, %{})
      assert %Action.Error.InvalidInputError{} = error
    end
  end

  describe "Zoi with string constraints" do
    defmodule StringConstraintAction do
      use Action,
        name: "string_constraint",
        description: "Action with Zoi string constraints",
        schema:
          Zoi.object(%{
            username: Zoi.string() |> Zoi.min(3) |> Zoi.max(20),
            password: Zoi.string() |> Zoi.min(8)
          })

      def run(params, _context) do
        {:ok, %{username: params.username}}
      end
    end

    test "validates with correct string lengths" do
      assert {:ok, result} =
               Exec.run(
                 StringConstraintAction,
                 %{username: "alice", password: "secret123"},
                 %{}
               )

      assert result.username == "alice"
    end

    test "rejects username too short" do
      assert {:error, error} =
               Exec.run(
                 StringConstraintAction,
                 %{username: "ab", password: "secret123"},
                 %{}
               )

      assert %Action.Error.InvalidInputError{} = error
      assert error.message =~ "username"
    end
  end

  describe "Zoi with integer constraints" do
    defmodule IntegerConstraintAction do
      use Action,
        name: "integer_constraint",
        description: "Action with Zoi integer constraints",
        schema:
          Zoi.object(%{
            score: Zoi.integer() |> Zoi.min(0) |> Zoi.max(100)
          })

      def run(params, _context) do
        {:ok, %{score: params.score}}
      end
    end

    test "validates with correct integer ranges" do
      assert {:ok, result} = Exec.run(IntegerConstraintAction, %{score: 85}, %{})
      assert result.score == 85
    end

    test "rejects score below minimum" do
      assert {:error, error} = Exec.run(IntegerConstraintAction, %{score: -1}, %{})
      assert %Action.Error.InvalidInputError{} = error
    end

    test "rejects score above maximum" do
      assert {:error, error} = Exec.run(IntegerConstraintAction, %{score: 101}, %{})
      assert %Action.Error.InvalidInputError{} = error
    end
  end

  describe "Zoi with list validation" do
    defmodule ListAction do
      use Action,
        name: "list_action",
        description: "Action with Zoi list validation",
        schema:
          Zoi.object(%{
            tags: Zoi.list(Zoi.string()) |> Zoi.min(1) |> Zoi.max(5)
          })

      def run(params, _context) do
        {:ok, %{tag_count: length(params.tags)}}
      end
    end

    test "validates lists with correct constraints" do
      assert {:ok, result} = Exec.run(ListAction, %{tags: ["elixir", "phoenix"]}, %{})
      assert result.tag_count == 2
    end

    test "rejects empty list when minimum is 1" do
      assert {:error, error} = Exec.run(ListAction, %{tags: []}, %{})
      assert %Action.Error.InvalidInputError{} = error
    end

    test "rejects list exceeding maximum" do
      assert {:error, error} = Exec.run(ListAction, %{tags: ["a", "b", "c", "d", "e", "f"]}, %{})
      assert %Action.Error.InvalidInputError{} = error
    end
  end

  describe "Zoi with enum validation" do
    defmodule EnumAction do
      use Action,
        name: "enum_action",
        description: "Action with Zoi enum validation",
        schema:
          Zoi.object(%{
            priority: Zoi.enum([:low, :normal, :high])
          })

      def run(params, _context) do
        {:ok, %{priority: params.priority}}
      end
    end

    test "validates with correct enum values" do
      assert {:ok, result} = Exec.run(EnumAction, %{priority: :high}, %{})
      assert result.priority == :high
    end

    test "rejects invalid enum value" do
      assert {:error, error} = Exec.run(EnumAction, %{priority: :critical}, %{})
      assert %Action.Error.InvalidInputError{} = error
    end
  end

  describe "Zoi output schema validation" do
    defmodule OutputSchemaAction do
      use Action,
        name: "output_schema_action",
        description: "Action with Zoi output schema validation",
        schema: Zoi.object(%{name: Zoi.string()}),
        output_schema:
          Zoi.object(%{
            greeting: Zoi.string() |> Zoi.min(1),
            length: Zoi.integer() |> Zoi.min(0)
          })

      def run(params, _context) do
        greeting = "Hello, #{params.name}!"

        {:ok,
         %{
           greeting: greeting,
           length: String.length(greeting),
           extra: "this field is allowed"
         }}
      end
    end

    defmodule InvalidOutputAction do
      use Action,
        name: "invalid_output",
        description: "Action that produces invalid output",
        output_schema:
          Zoi.object(%{
            required_field: Zoi.string()
          })

      def run(_params, _context) do
        {:ok, %{wrong_field: "oops"}}
      end
    end

    test "validates correct output" do
      assert {:ok, result} = Exec.run(OutputSchemaAction, %{name: "Alice"}, %{})
      assert result.greeting == "Hello, Alice!"
      assert result.length == 13
      assert result.extra == "this field is allowed"
    end

    test "returns error for invalid output" do
      assert {:error, error} = Exec.run(InvalidOutputAction, %{}, %{})
      assert %Action.Error.InvalidInputError{} = error
      assert error.message =~ "required_field"
    end
  end

  describe "Zoi JSON Schema generation" do
    defmodule AIToolAction do
      use Action,
        name: "ai_tool_action",
        description: "Action for AI tool integration",
        schema:
          Zoi.object(%{
            query: Zoi.string(description: "Search query") |> Zoi.min(1),
            limit: Zoi.integer(description: "Maximum results")
          })

      def run(params, _context) do
        {:ok, %{query: params.query, limit: params.limit}}
      end
    end

    test "generates JSON schema from Zoi schema" do
      schema = AIToolAction.schema()
      json_schema = Action.Schema.to_json_schema(schema)

      assert json_schema[:type] == :object
      assert Map.has_key?(json_schema[:properties], :query)
      assert Map.has_key?(json_schema[:properties], :limit)
    end

    test "provides action metadata" do
      assert AIToolAction.name() == "ai_tool_action"
      assert AIToolAction.description() == "Action for AI tool integration"
    end
  end

  describe "Interoperability with NimbleOptions" do
    defmodule LegacyAction do
      use Action,
        name: "legacy",
        description: "NimbleOptions action",
        schema: [value: [type: :integer, required: true]]

      def run(params, _context) do
        {:ok, %{doubled: params.value * 2}}
      end
    end

    defmodule ModernAction do
      use Action,
        name: "modern",
        description: "Zoi action",
        schema: Zoi.object(%{value: Zoi.integer()})

      def run(params, _context) do
        {:ok, %{tripled: params.value * 3}}
      end
    end

    test "NimbleOptions actions still work" do
      assert {:ok, result} = Exec.run(LegacyAction, %{value: 5}, %{})
      assert result.doubled == 10
    end

    test "Zoi actions work" do
      assert {:ok, result} = Exec.run(ModernAction, %{value: 5}, %{})
      assert result.tripled == 15
    end

    test "both work together" do
      {:ok, legacy_result} = Exec.run(LegacyAction, %{value: 10}, %{})
      {:ok, modern_result} = Exec.run(ModernAction, %{value: legacy_result.doubled}, %{})
      assert modern_result.tripled == 60
    end
  end
end
