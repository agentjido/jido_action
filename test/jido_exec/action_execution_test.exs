defmodule Jido.Exec.ActionExecutionTest do
  use JidoTest.ActionCase, async: true
  @moduletag capture_log: true

  alias Jido.Action.Error.{ConfigurationError, ExecutionFailureError, InvalidInputError}
  alias Jido.Exec
  alias Jido.Flow
  alias Jido.Flow.{Node, Ref}
  alias Jido.Instruction
  alias JidoTest.ExecFixtures.ActionWithFlowFunction

  alias JidoTest.TestActions.{
    Add,
    AtomErrorAction,
    AtomValidationAction,
    ErrorAction,
    ErrorWithExtrasAction,
    ExceptionErrorAction,
    ExtrasAction,
    InvalidValidatedOutputAction,
    InvalidValidatedParamsAction,
    InvalidValidationResultAction,
    NoneExtrasAction,
    OutputEnvelopeAction,
    RaisingOutputValidationAction,
    RaisingValidationAction,
    RawOutputAction,
    RawOutputWithExtrasAction,
    ThrowingAction,
    StacktraceAction,
    StacktraceValidationAction,
    TupleErrorAction,
    UnsupportedResult
  }

  describe "run/3 with action modules" do
    test "executes a leaf action with input and context validation" do
      assert {:ok, %{value: 6}} = Exec.run(Add, %{value: 5}, %{trace_id: "trace"})
    end

    test "executes action modules that happen to export flow/0 as actions" do
      assert {:ok, %{value: 5, executed_as: :action}} =
               Exec.run(ActionWithFlowFunction, %{value: 5}, %{})
    end

    test "normalizes keyword input and context for leaf actions" do
      assert {:ok, %{value: 6}} = Exec.run(Add, [value: 5], trace_id: "trace")
    end

    test "preserves action extras from leaf actions" do
      assert {:ok, %{value: 5}, %{trace_id: "trace"}} =
               Exec.run(ExtrasAction, %{value: 5}, %{trace_id: "trace"})

      assert {:ok, %{value: 5}, :none} =
               Exec.run(NoneExtrasAction, %{value: 5}, %{})
    end

    test "validates explicit output envelopes from leaf actions" do
      assert {:ok, %Jido.Action.Output{kind: :raw, value: %{value: 3}, meta: %{source: :test}}} =
               Exec.run(OutputEnvelopeAction, %{value: 3}, %{})
    end

    test "requires output envelopes for raw and stream values" do
      for value <- [42, Stream.map(1..3, & &1)] do
        assert {:error, %ExecutionFailureError{message: message, details: details}} =
                 Exec.run(RawOutputAction, %{value: value}, %{})

        assert message == "action returned a value that requires an output envelope"
        assert details.action == RawOutputAction
      end

      instruction =
        Instruction.new!(action: RawOutputWithExtrasAction, params: %{value: 42})

      for executable <- [RawOutputWithExtrasAction, instruction] do
        assert {:error, %ExecutionFailureError{}, %{effect: :already_ran}} =
                 Exec.run(executable, %{value: 42}, %{})
      end
    end

    test "validates action params before calling run" do
      assert {:error, %InvalidInputError{message: message}} =
               Exec.run(Add, %{value: "bad"}, %{})

      assert message =~ "expected integer"
    end

    test "returns action errors without Runic-specific wrapping" do
      assert {:error, %ExecutionFailureError{message: message}} =
               Exec.run(ErrorAction, %{error_type: :validation}, %{})

      refute message =~ "Runic"
    end

    test "normalizes three-element action error tuples" do
      assert {:error, %ExecutionFailureError{message: message, details: details}, extras} =
               Exec.run(ErrorWithExtrasAction, %{reason: :bad_with_extras}, %{})

      assert message == "bad_with_extras"
      assert details.reason == :bad_with_extras
      assert extras == %{ignored: true}
    end

    test "preserves exception action errors returned by leaf actions" do
      assert {:error, %ExecutionFailureError{message: message, details: details}} =
               Exec.run(ExceptionErrorAction, %{}, %{})

      assert message == "already wrapped"
      assert details.source == :test
    end

    test "normalizes atom and tuple action error reasons" do
      assert {:error, %ExecutionFailureError{message: "bad_atom"}} =
               Exec.run(AtomErrorAction, %{}, %{})

      assert {:error, %ExecutionFailureError{message: "{:bad, :tuple}"}} =
               Exec.run(TupleErrorAction, %{}, %{})
    end

    test "converts raised leaf action exceptions to execution errors" do
      assert {:error, %ExecutionFailureError{message: message, details: details}} =
               Exec.run(ErrorAction, %{error_type: :runtime}, %{})

      assert message =~ "Runtime error"
      assert details.action == ErrorAction
      assert details.exception == RuntimeError
    end

    test "preserves the original Action stacktrace for raised exceptions" do
      assert {:error, %ExecutionFailureError{} = error} =
               Exec.run(StacktraceAction, %{mode: :raise}, %{})

      assert_action_frame(error, StacktraceAction, :raise_from_action, 0)

      assert %Splode.Stacktrace{stacktrace: [{module, _function, _arity, _location} | _rest]} =
               error.stacktrace

      assert module == StacktraceAction
    end

    test "preserves the original Action stacktrace for throws and exits" do
      for {mode, reason, function} <- [
            {:throw, :stacktrace_probe_thrown, :throw_from_action},
            {:exit, :stacktrace_probe_exited, :exit_from_action}
          ] do
        assert {:error, %ExecutionFailureError{details: details} = error} =
                 Exec.run(StacktraceAction, %{mode: mode}, %{})

        assert details.reason == reason
        assert_action_frame(error, StacktraceAction, function, 0)
      end
    end

    test "preserves the original validator stacktrace" do
      for {mode, function} <- [
            {:input, :raise_from_input_validator},
            {:output, :raise_from_output_validator}
          ] do
        assert {:error, %ExecutionFailureError{} = error} =
                 Exec.run(StacktraceValidationAction, %{mode: mode}, %{})

        assert_action_frame(error, StacktraceValidationAction, function, 0)
      end
    end

    test "keeps caught stacktraces out of the stable error map and JSON output" do
      assert {:error, %ExecutionFailureError{} = error} =
               Exec.run(StacktraceAction, %{mode: :raise}, %{})

      assert Map.keys(Jido.Action.Error.to_map(error)) |> Enum.sort() ==
               [:details, :message, :retryable?, :type]

      refute Map.has_key?(Jido.Action.Error.to_map(error), :stacktrace)
      assert is_binary(JSON.encode!(error))
    end

    test "converts unsupported action result shapes to execution errors" do
      assert {:error, %ExecutionFailureError{message: message, details: details}} =
               Exec.run(UnsupportedResult)

      assert message =~ "action returned an unsupported result"
      assert details.action == UnsupportedResult
      assert details.result == :not_a_result_tuple
    end

    test "converts thrown action values to execution errors" do
      assert {:error, %ExecutionFailureError{message: message, details: details}} =
               Exec.run(ThrowingAction)

      assert message =~ "action throw"
      assert details.action == ThrowingAction
      assert details.reason == :thrown_value
    end

    test "normalizes validator failures and unsupported results" do
      assert {:error, %ExecutionFailureError{message: "bad_params"}} =
               Exec.run(AtomValidationAction)

      assert {:error, %ExecutionFailureError{message: message, details: details}} =
               Exec.run(InvalidValidationResultAction)

      assert message == "action validator returned an unsupported result"
      assert details.callback == :validate_params
      assert details.result == :ok

      assert {:error, %ExecutionFailureError{message: "validator failed", details: details}} =
               Exec.run(RaisingValidationAction)

      assert details.callback == :validate_params

      assert {:error,
              %ExecutionFailureError{message: "output validator failed", details: details}} =
               Exec.run(RaisingOutputValidationAction)

      assert details.callback == :validate_output

      for {action, callback} <- [
            {InvalidValidatedParamsAction, :validate_params},
            {InvalidValidatedOutputAction, :validate_output}
          ] do
        assert {:error, %ExecutionFailureError{details: details}} = Exec.run(action)
        assert details.callback == callback
        assert details.result == 42
      end
    end
  end

  describe "run/3 with instructions" do
    test "executes an instruction and merges call-site input and context" do
      instruction =
        Instruction.new!(
          action: Add,
          params: %{value: 5, amount: 1},
          context: %{trace_id: "base"}
        )

      assert {:ok, %{value: 8}} =
               Exec.run(instruction, %{amount: 3}, %{tenant_id: "tenant"})
    end

    test "returns validation errors when instruction call-site input is invalid" do
      instruction = Instruction.new!(action: Add)

      assert {:error, %InvalidInputError{message: message}} =
               Exec.run(instruction, :not_params, %{})

      assert message =~ "expected params to be a map or keyword list"
    end

    test "returns validation errors for malformed raw instruction structs" do
      instruction = %Instruction{action: "not_a_module", params: %{}, context: %{}}

      assert {:error, %InvalidInputError{message: "Invalid instruction configuration"}} =
               Exec.run(instruction)
    end
  end

  test "rejects unknown executable values with a configuration error" do
    assert {:error, %ConfigurationError{message: message}} = Exec.run(:not_a_real_executable)
    assert message =~ "unknown executable"
  end

  test "rejects unsupported executable values with a configuration error" do
    assert {:error, %ConfigurationError{message: message, details: details}} =
             Exec.run("not executable")

    assert message =~ "unknown executable"
    assert details.executable == "not executable"
  end

  test "preserves Action stacktraces through serial and asynchronous Flow nodes" do
    flow =
      Flow.new!(
        name: "stacktrace_flow",
        nodes: [
          Node.new!(
            name: "failure",
            action: StacktraceAction,
            input: %{mode: Ref.value(:raise)}
          )
        ],
        return: Ref.result("failure")
      )

    for opts <- [[], [async: true]] do
      assert {:error, %ExecutionFailureError{} = error} = Exec.run(flow, %{}, %{}, opts)
      assert_action_frame(error, StacktraceAction, :raise_from_action, 0)
    end
  end

  test "preserves validator stacktraces when a Flow retags an input failure" do
    flow =
      Flow.new!(
        name: "validator_stacktrace_flow",
        nodes: [
          Node.new!(
            name: "failure",
            action: StacktraceValidationAction,
            input: %{mode: Ref.value(:input)}
          )
        ],
        return: Ref.result("failure")
      )

    assert {:error, %InvalidInputError{} = error} = Exec.run(flow)
    assert_action_frame(error, StacktraceValidationAction, :raise_from_input_validator, 0)
  end

  defp assert_action_frame(error, module, function, arity) do
    assert %Splode.Stacktrace{stacktrace: stacktrace} = error.stacktrace

    assert Enum.any?(stacktrace, fn
             {^module, ^function, ^arity, _location} -> true
             _frame -> false
           end)
  end
end
