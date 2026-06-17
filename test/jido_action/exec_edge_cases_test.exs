defmodule JidoTest.ExecEdgeCasesTest do
  @moduledoc """
  Additional edge case tests to achieve >90% coverage for lib/jido_action/exec.ex
  """

  use JidoTest.ActionCase, async: false
  use Mimic

  import ExUnit.CaptureLog

  alias Jido.Action.Error
  alias Jido.Exec
  alias JidoTest.TestActions.DelayAction
  alias JidoTest.TestActions.EchoAction

  @moduletag :capture_log

  setup :set_mimic_global

  setup do
    Logger.put_process_level(self(), :debug)

    on_exit(fn ->
      Logger.delete_process_level(self())
    end)

    :ok
  end

  describe "error handling edge cases with directives" do
    test "handles errors with directive tuples" do
      defmodule DirectiveErrorAction do
        use Jido.Action,
          name: "directive_error",
          description: "Action that returns error with directive"

        def run(_params, _context) do
          directive = %{type: "test_directive", data: "test"}
          {:error, Error.execution_error("error with directive"), directive}
        end
      end

      capture_log(fn ->
        assert {:error, %Error.ExecutionFailureError{}, directive} =
                 Exec.run(DirectiveErrorAction, %{}, %{}, [])

        assert directive.type == "test_directive"
      end)
    end
  end

  describe "task execution edge cases" do
    test "handles killed task in timeout execution" do
      defmodule KillableAction do
        use Jido.Action,
          name: "killable",
          description: "Action that can be killed"

        def run(_params, _context) do
          # Simulate getting killed
          Process.exit(self(), :kill)
          {:ok, %{}}
        end
      end

      capture_log(fn ->
        assert {:error, %Error.ExecutionFailureError{}} =
                 Exec.run(KillableAction, %{}, %{}, timeout: 1000)
      end)
    end

    test "handles task exit with reason" do
      defmodule ExitingTaskAction do
        use Jido.Action,
          name: "exiting_task",
          description: "Action that exits with reason"

        def run(_params, _context) do
          Process.exit(self(), {:shutdown, :custom_reason})
          {:ok, %{}}
        end
      end

      capture_log(fn ->
        assert {:error, %Error.ExecutionFailureError{}} =
                 Exec.run(ExitingTaskAction, %{}, %{}, timeout: 1000)
      end)
    end

    test "handles task cleanup on timeout" do
      # This test exercises Task.Supervisor cleanup on timeout
      capture_log(fn ->
        # Start a long-running action that will timeout and trigger cleanup
        assert {:error, %Error.TimeoutError{}} =
                 Exec.run(DelayAction, %{delay: 5000}, %{}, timeout: 100)
      end)
    end
  end

  describe "action result edge cases" do
    test "handles action returning 3-tuple success with directive" do
      defmodule ThreeTupleSuccessAction do
        use Jido.Action,
          name: "three_tuple_success",
          description: "Action returning 3-tuple success"

        def run(params, _context) do
          directive = %{type: "success_directive", data: "test"}
          {:ok, params, directive}
        end
      end

      capture_log(fn ->
        assert {:ok, %{value: 42}, directive} =
                 Exec.run(ThreeTupleSuccessAction, %{value: 42}, %{}, [])

        assert directive.type == "success_directive"
      end)
    end

    test "handles action output validation with 3-tuple" do
      defmodule ThreeTupleValidationAction do
        use Jido.Action,
          name: "three_tuple_validation",
          description: "Action with 3-tuple and validation"

        def run(params, _context) do
          directive = %{type: "validation_directive"}
          {:ok, params, directive}
        end
      end

      capture_log(fn ->
        assert {:ok, %{value: 1}, directive} =
                 Exec.run(ThreeTupleValidationAction, %{value: 1}, %{}, [])

        assert directive.type == "validation_directive"
      end)
    end

    test "handles action 3-tuple success results" do
      # Test that 3-tuple success results work correctly
      defmodule Simple3TupleAction do
        use Jido.Action,
          name: "simple_three_tuple",
          description: "Action with simple 3-tuple result"

        def run(params, _context) do
          directive = %{type: "simple_directive"}
          {:ok, params, directive}
        end
      end

      capture_log(fn ->
        assert {:ok, %{value: 1}, directive} =
                 Exec.run(Simple3TupleAction, %{value: 1}, %{}, [])

        assert directive.type == "simple_directive"
      end)
    end
  end

  describe "exception handling in execute_action" do
    test "handles RuntimeError in action execution" do
      defmodule RuntimeErrorAction do
        use Jido.Action,
          name: "runtime_error",
          description: "Action that raises RuntimeError"

        def run(_params, _context) do
          raise "runtime error occurred"
        end
      end

      capture_log(fn ->
        assert {:error, %Error.ExecutionFailureError{}} =
                 Exec.run(RuntimeErrorAction, %{}, %{}, [])
      end)
    end

    test "handles ArgumentError in action execution" do
      defmodule ArgumentErrorAction do
        use Jido.Action,
          name: "argument_error",
          description: "Action that raises ArgumentError"

        def run(_params, _context) do
          raise ArgumentError, "invalid argument"
        end
      end

      capture_log(fn ->
        assert {:error, %Error.ExecutionFailureError{}} =
                 Exec.run(ArgumentErrorAction, %{}, %{}, [])
      end)
    end

    test "handles other exceptions in action execution" do
      defmodule OtherExceptionAction do
        use Jido.Action,
          name: "other_exception",
          description: "Action that raises other exception"

        def run(_params, _context) do
          raise KeyError, "key not found"
        end
      end

      capture_log(fn ->
        assert {:error, %Error.ExecutionFailureError{}} =
                 Exec.run(OtherExceptionAction, %{}, %{}, [])
      end)
    end
  end

  describe "additional normalization edge cases" do
    test "normalize_params with nested {:ok, {:ok, params}}" do
      # Test nested ok tuples
      nested_ok = {:ok, {:ok, %{key: "value"}}}
      assert {:error, %Error.InvalidInputError{}} = Exec.run(EchoAction, nested_ok)
    end

    test "normalize_params with complex nested error" do
      nested_error = {:error, {:nested, "error"}}
      assert {:error, %Error.InvalidInputError{}} = Exec.run(EchoAction, nested_error)
    end
  end
end
