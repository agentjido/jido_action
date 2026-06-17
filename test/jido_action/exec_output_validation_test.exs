defmodule JidoTest.Exec.OutputValidationTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Exec
  alias JidoTest.TestActions.InvalidOutputAction
  alias JidoTest.TestActions.NoOutputSchemaAction
  alias JidoTest.TestActions.OutputCallbackAction
  alias JidoTest.TestActions.OutputSchemaAction

  @moduletag :capture_log

  describe "output validation integration with Exec" do
    test "successful action with valid output" do
      params = %{input: "hello"}
      context = %{}

      assert {:ok, result} = Exec.run(OutputSchemaAction, params, context)
      assert result.result == "HELLO"
      assert result.length == 5
      assert result.extra == "not validated"
    end

    test "action with invalid output fails execution" do
      params = %{}
      context = %{}

      assert {:error, %Jido.Action.Error.InvalidInputError{message: error_message}} =
               Exec.run(InvalidOutputAction, params, context)

      assert error_message =~ "required"
      assert error_message =~ "required_field"
    end

    test "action without output schema succeeds without validation" do
      params = %{}
      context = %{}

      assert {:ok, result} = Exec.run(NoOutputSchemaAction, params, context)
      assert result.anything == "goes"
      assert result.here == 123
    end

    test "output validation without lifecycle callbacks" do
      params = %{input: 42}
      context = %{}

      assert {:ok, result} = Exec.run(OutputCallbackAction, params, context)
      assert result.value == 42
      refute Map.has_key?(result, :preprocessed)
      refute Map.has_key?(result, :postprocessed)
    end

    test "output validation with async execution" do
      params = %{input: "world"}

      async_ref = Exec.run_async(OutputSchemaAction, params, %{})
      assert {:ok, result} = Exec.await(async_ref)

      assert result.result == "WORLD"
      assert result.length == 5
      assert result.extra == "not validated"
    end

    test "async execution with invalid output fails" do
      async_ref = Exec.run_async(InvalidOutputAction, %{}, %{})

      assert {:error, %Jido.Action.Error.InvalidInputError{message: error_message}} =
               Exec.await(async_ref)

      assert error_message =~ "required"
      assert error_message =~ "required_field"
    end

    test "output validation works with action returning tuple with directive" do
      # We need to create a test action that returns {:ok, result, directive}
      defmodule TupleOutputAction do
        use Jido.Action,
          name: "tuple_output_action",
          output_schema: Zoi.object(%{status: Zoi.string()})

        def run(_params, _context) do
          {:ok, %{status: "success", extra: "data"}, :continue}
        end
      end

      assert {:ok, result, directive} = Exec.run(TupleOutputAction, %{}, %{})
      assert result.status == "success"
      assert result.extra == "data"
      assert directive == :continue
    end

    test "output validation fails with tuple return format" do
      defmodule InvalidTupleOutputAction do
        use Jido.Action,
          name: "invalid_tuple_output_action",
          output_schema: Zoi.object(%{required_field: Zoi.string()})

        def run(_params, _context) do
          {:ok, %{wrong_field: "value"}, :continue}
        end
      end

      assert {:error, %Jido.Action.Error.InvalidInputError{}, directive} =
               Exec.run(InvalidTupleOutputAction, %{}, %{})

      assert directive == :continue
    end

    test "output validation preserves unknown fields" do
      params = %{input: "test"}

      assert {:ok, result} = Exec.run(OutputSchemaAction, params, %{})

      # Known fields are validated
      assert result.result == "TEST"
      assert result.length == 4

      # Unknown fields are preserved
      assert result.extra == "not validated"
    end
  end

  describe "output validation error handling" do
    test "output validation errors are properly formatted" do
      defmodule TypeErrorOutputAction do
        use Jido.Action,
          name: "type_error_output_action",
          output_schema: Zoi.object(%{count: Zoi.integer()})

        def run(_params, _context) do
          {:ok, %{count: "not an integer"}}
        end
      end

      assert {:error, %Jido.Action.Error.InvalidInputError{message: error_message}} =
               Exec.run(TypeErrorOutputAction, %{}, %{})

      assert error_message =~ "count"
      assert error_message =~ "expected integer"
    end
  end
end
