defmodule JidoTest.Exec.ActionTest do
  use JidoTest.ActionCase, async: true
  use ExUnitProperties

  alias Jido.Action
  alias Jido.Action.Error
  alias JidoTest.TestActions.Add
  alias JidoTest.TestActions.ConcurrentAction
  alias JidoTest.TestActions.Divide
  alias JidoTest.TestActions.ErrorAction
  alias JidoTest.TestActions.FullAction
  alias JidoTest.TestActions.LongRunningAction
  alias JidoTest.TestActions.Multiply
  alias JidoTest.TestActions.NoOutputSchemaAction
  alias JidoTest.TestActions.NoSchema
  alias JidoTest.TestActions.OutputSchemaAction
  alias JidoTest.TestActions.RateLimitedAction
  alias JidoTest.TestActions.StreamingAction
  alias JidoTest.TestActions.Subtract

  @moduletag :capture_log

  describe "error formatting" do
    test "format_config_error formats NimbleOptions.ValidationError" do
      error = %NimbleOptions.ValidationError{keys_path: [:name], message: "is invalid"}
      formatted = Error.format_nimble_config_error(error, "Action", __MODULE__)

      assert formatted ==
               "Invalid configuration given to use Jido.Action (#{__MODULE__}) for key [:name]: is invalid"
    end

    test "format_nimble_validation_error formats NimbleOptions.ValidationError" do
      error = %NimbleOptions.ValidationError{keys_path: [:input], message: "is required"}
      formatted = Error.format_nimble_validation_error(error, "Action", __MODULE__)
      assert formatted == "Invalid parameters for Action (#{__MODULE__}) at [:input]: is required"
    end
  end

  describe "action creation and metadata" do
    test "creates a valid action with retained metadata" do
      assert FullAction.name() == "full_action"
      assert FullAction.description() == "A full action for testing"

      assert FullAction.schema() == [
               a: [type: :integer, required: true],
               b: [type: :integer, required: true]
             ]
    end

    test "creates a valid action with no schema" do
      assert NoSchema.name() == "add_two"
      assert NoSchema.description() == "Adds 2 to the input value"
      assert NoSchema.schema() == []
    end
  end

  describe "parameter validation" do
    test "validates required parameters" do
      assert {:error, %Jido.Action.Error.InvalidInputError{message: message}} =
               FullAction.validate_params(%{})

      assert message =~ "required :a option not found"
    end

    test "validates parameter types" do
      assert {:error, %Jido.Action.Error.InvalidInputError{message: message}} =
               FullAction.validate_params(%{a: "not an integer", b: 2})

      assert message =~ "expected integer"
    end
  end

  describe "action execution" do
    test "executes a valid action successfully" do
      assert {:ok, result} = FullAction.run(%{a: 5, b: 2}, %{})
      assert result.a == 5
      assert result.b == 2
      assert result.result == 7
    end

    test "executes basic calculator actions" do
      assert {:ok, %{value: 6}} = Add.run(%{value: 5, amount: 1}, %{})
      assert {:ok, %{value: 10}} = Multiply.run(%{value: 5, amount: 2}, %{})
      assert {:ok, %{value: 3}} = Subtract.run(%{value: 5, amount: 2}, %{})
      assert {:ok, %{value: 2.5}} = Divide.run(%{value: 5, amount: 2}, %{})
    end

    test "handles division by zero" do
      assert_raise RuntimeError, "Cannot divide by zero", fn ->
        Divide.run(%{value: 5, amount: 0}, %{})
      end
    end

    test "handles different error scenarios" do
      assert {:error, "Validation error"} =
               ErrorAction.run(%{error_type: :validation}, %{})

      assert_raise RuntimeError, "Runtime error", fn ->
        ErrorAction.run(%{error_type: :runtime}, %{})
      end
    end
  end

  describe "error handling" do
    test "new returns an error tuple" do
      assert {:error, error} = Action.new()
      assert is_exception(error)
      assert Exception.message(error) =~ "Actions should not be defined at runtime"
    end
  end

  describe "property-based tests" do
    property "valid action always returns a result for valid input" do
      check all(
              a <- integer(),
              b <- integer(1..1000)
            ) do
        params = %{a: a, b: b}
        assert {:ok, result} = FullAction.run(params, %{})
        assert result.a == a
        assert result.b == b
        assert result.result == a + b
      end
    end
  end

  describe "advanced actions" do
    test "long running action" do
      assert {:ok, "Exec completed"} = LongRunningAction.run(%{}, %{})
    end

    test "rate limited action" do
      Enum.each(1..5, fn _ ->
        assert {:ok, _} = RateLimitedAction.run(%{action: "test"}, %{})
      end)

      assert {:error, "Rate limit exceeded. Please try again later."} =
               RateLimitedAction.run(%{action: "test"}, %{})
    end

    test "streaming action" do
      assert {:ok, %{stream: stream}} =
               StreamingAction.run(%{chunk_size: 2, total_items: 10}, %{})

      assert Enum.to_list(stream) == [3, 7, 11, 15, 19]
    end

    test "concurrent action" do
      assert {:ok, %{results: results}} = ConcurrentAction.run(%{inputs: [1, 2, 3, 4, 5]}, %{})
      assert length(results) == 5
      assert Enum.all?(results, fn r -> r in [2, 4, 6, 8, 10] end)
    end
  end

  describe "output validation" do
    test "action with valid output schema validates successfully" do
      assert {:ok, result} =
               OutputSchemaAction.validate_output(%{result: "test", length: 4, extra: "data"})

      assert result.result == "test"
      assert result.length == 4
      assert result.extra == "data"
    end

    test "action with invalid output fails validation" do
      assert {:error, %Jido.Action.Error.InvalidInputError{message: message}} =
               OutputSchemaAction.validate_output(%{result: "test"})

      assert message =~ "required :length option not found"
    end

    test "action without output schema skips validation" do
      assert {:ok, result} = NoOutputSchemaAction.validate_output(%{anything: "goes"})
      assert result.anything == "goes"
    end
  end
end
