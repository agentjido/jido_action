defmodule Jido.Action.ZoiSchemaTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Action

  describe "Basic Zoi schema validation via direct action contract" do
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
      assert {:ok, result} = run_action(BasicZoiAction, %{name: "Alice", age: 30})
      assert result.greeting == "Hello Alice, age 30"
    end

    test "returns validation error for invalid types" do
      assert {:error, error} = run_action(BasicZoiAction, %{name: "Bob", age: "invalid"})
      assert %Action.Error.InvalidInputError{} = error
      assert error.message =~ "age"
    end

    test "returns validation error for missing required fields" do
      assert {:error, error} = run_action(BasicZoiAction, %{name: "Charlie"})
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
      assert {:ok, result} = run_action(OutputSchemaAction, %{name: "Alice"})
      assert result.greeting == "Hello, Alice!"
      assert result.length == 13
      assert result.extra == "this field is allowed"
    end

    test "returns error for invalid output" do
      assert {:error, error} = run_action(InvalidOutputAction, %{})
      assert %Action.Error.InvalidInputError{} = error
      assert error.message =~ "required_field"
    end
  end
end
