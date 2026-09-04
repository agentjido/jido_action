defmodule JidoActionTest.Exec.ActionExecutionTest do
  use JidoActionTest.Case, async: true
  @moduletag capture_log: true

  alias Jido.Action.Error
  alias Jido.Action.Error.{ConfigurationError, ExecutionFailureError, InvalidInputError}
  alias Jido.Exec
  alias Jido.Flow
  alias Jido.Flow.{Ref, Step}
  alias Jido.Instruction
  alias JidoActionTest.Fixtures.ActionWithFlowFunction
  alias JidoActionTest.Fixtures.InlineResultFlow

  alias JidoActionTest.Fixtures.Actions.{
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
    MissingRun,
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

  defmodule RaisingActionName do
    def __jido_executable__, do: Jido.Executable.action(__MODULE__)
    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
    def run(params, _context), do: {:ok, params}
    def name, do: raise("action name failed")
  end

  defmodule ThrowingActionName do
    def __jido_executable__, do: Jido.Executable.action(__MODULE__)
    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
    def run(params, _context), do: {:ok, params}
    def name, do: throw(:action_name_failed)
  end

  test "inline targets keep normal success, Output, and extras rules" do
    action = InlineResultFlow.step_action("result")
    assert action.schema() == []
    assert action.output_schema() == []

    for {mode, value, expected} <- [
          {:map, 3, %{value: 3}},
          {:output, "raw success", Jido.Action.Output.raw("raw success")}
        ] do
      input = %{mode: mode, value: value}
      assert Exec.run(action, input) == {:ok, expected}
      assert Exec.run(InlineResultFlow, input) == {:ok, expected}
    end

    input = %{mode: :extras, value: 3}
    instruction = Instruction.new!(target: action, params: input)

    for target <- [action, instruction] do
      assert Exec.run(target, input) == {:ok, %{value: 3}, %{effect: :already_ran}}
    end

    explicit_flow =
      Flow.new!(
        name: "explicit_inline_result",
        components: [Step.new!(name: "result", action: action, params: Ref.input([]))],
        output: Ref.result("result")
      )

    for flow <- [InlineResultFlow, explicit_flow] do
      assert Exec.run(flow, input) == {:ok, %{value: 3}}
      assert {:ok, execution} = Exec.start(flow, input)
      assert {:ok, execution} = Exec.continue(execution)
      assert Exec.result(execution) == {:ok, %{value: 3}}
    end
  end

  test "inline callback failures retain current structured errors in Actions and Steps" do
    action = InlineResultFlow.step_action("result")

    cases = [
      {:raise, "inline body failed", %{exception: RuntimeError}},
      {:throw, "action throw", %{reason: {:inline_throw, 42}}},
      {:exit, "action exit", %{reason: {:inline_exit, 42}}},
      {:invalid_callback, "action returned an unsupported result",
       %{result: :not_a_result_tuple}},
      {:invalid_output, "action returned a value that requires an output envelope",
       %{callback: :run, output: 42}}
    ]

    for {mode, message, expected_details} <- cases, target <- [action, InlineResultFlow] do
      assert {:error, %ExecutionFailureError{} = error} =
               Exec.run(target, %{mode: mode, value: 42})

      assert error.message == message
      assert error.details.action == action
      assert Map.take(error.details, Map.keys(expected_details)) == expected_details
      refute Error.retryable?(error)
      if target == InlineResultFlow, do: assert(error.details.node == "result")

      if mode in [:raise, :throw, :exit] do
        assert %Splode.Stacktrace{stacktrace: stacktrace} = error.stacktrace

        assert Enum.any?(stacktrace, fn
                 {InlineResultFlow, _function, _arity, location} ->
                   to_string(location[:file]) =~ "test/support/fixtures/flow/inline.ex" and
                     is_integer(location[:line])

                 _frame ->
                   false
               end)
      end
    end
  end

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
        assert {:error, %ExecutionFailureError{message: message, details: details} = error} =
                 Exec.run(RawOutputAction, %{value: value}, %{})

        refute Error.retryable?(error)
        assert message == "action returned a value that requires an output envelope"
        assert details.action == RawOutputAction
      end

      instruction =
        Instruction.new!(target: RawOutputWithExtrasAction, params: %{value: 42})

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
      assert {:error, %ExecutionFailureError{message: "bad_atom"} = atom_error} =
               Exec.run(AtomErrorAction, %{}, %{})

      assert {:error, %ExecutionFailureError{message: "{:bad, :tuple}"} = tuple_error} =
               Exec.run(TupleErrorAction, %{}, %{})

      refute Jido.Action.Error.retryable?(atom_error)
      refute Jido.Action.Error.retryable?(tuple_error)
    end

    test "converts raised leaf action exceptions to execution errors" do
      assert {:error, %ExecutionFailureError{message: message, details: details} = error} =
               Exec.run(ErrorAction, %{error_type: :runtime}, %{})

      refute Error.retryable?(error)
      assert message =~ "Runtime error"
      assert details.action == ErrorAction
      assert details.exception == RuntimeError
    end

    test "preserves the original Action stacktrace for raised exceptions" do
      assert {:error, %ExecutionFailureError{} = error} =
               Exec.run(StacktraceAction, %{mode: :raise}, %{})

      refute Error.retryable?(error)
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

        refute Error.retryable?(error)
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
      assert {:error, %ExecutionFailureError{message: message, details: details} = error} =
               Exec.run(UnsupportedResult)

      refute Error.retryable?(error)
      assert message =~ "action returned an unsupported result"
      assert details.action == UnsupportedResult
      assert details.result == :not_a_result_tuple
    end

    test "converts thrown action values to execution errors" do
      assert {:error, %ExecutionFailureError{message: message, details: details} = error} =
               Exec.run(ThrowingAction)

      refute Error.retryable?(error)
      assert message =~ "action throw"
      assert details.action == ThrowingAction
      assert details.reason == :thrown_value
    end

    test "normalizes validator failures and unsupported results" do
      assert {:error, %ExecutionFailureError{message: "bad_params"} = params_error} =
               Exec.run(AtomValidationAction)

      refute Jido.Action.Error.retryable?(params_error)

      assert {:error, %ExecutionFailureError{message: message, details: details} = error} =
               Exec.run(InvalidValidationResultAction)

      assert message == "action validator returned an unsupported result"
      refute Error.retryable?(error)
      assert details.callback == :validate_params
      assert details.result == :ok

      assert {:error,
              %ExecutionFailureError{message: "validator failed", details: details} = error} =
               Exec.run(RaisingValidationAction)

      refute Error.retryable?(error)
      assert details.callback == :validate_params

      assert {:error,
              %ExecutionFailureError{message: "output validator failed", details: details} =
                error} =
               Exec.run(RaisingOutputValidationAction)

      refute Error.retryable?(error)
      assert details.callback == :validate_output

      for {action, callback} <- [
            {InvalidValidatedParamsAction, :validate_params},
            {InvalidValidatedOutputAction, :validate_output}
          ] do
        assert {:error, %ExecutionFailureError{details: details} = error} = Exec.run(action)
        refute Error.retryable?(error)
        assert details.callback == callback
        assert details.result == 42
      end
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

  test "Exec contains Action boundary failures" do
    assert {:error, %InvalidInputError{}} = Exec.run(MissingRun)

    assert {:error, %InvalidInputError{details: %{executable_type: :action}}} =
             Exec.start(Add)

    assert {:error, %InvalidInputError{}} = Exec.run(Add, :invalid)

    for module <- [RaisingActionName, ThrowingActionName] do
      assert {:ok, %{}} = Exec.run(module)
    end
  end

  test "preserves Action stacktraces through serial and concurrent Flow nodes" do
    flow =
      Flow.new!(
        name: "stacktrace_flow",
        components: [
          Step.new!(
            name: "failure",
            action: StacktraceAction,
            params: %{mode: :raise}
          )
        ],
        output: Ref.result("failure")
      )

    for opts <- [[], [max_concurrency: 8]] do
      assert {:error, %ExecutionFailureError{} = error} = Exec.run(flow, %{}, %{}, opts)
      assert_action_frame(error, StacktraceAction, :raise_from_action, 0)
    end
  end

  test "preserves validator stacktraces when a Flow retags an input failure" do
    flow =
      Flow.new!(
        name: "validator_stacktrace_flow",
        components: [
          Step.new!(
            name: "failure",
            action: StacktraceValidationAction,
            params: %{mode: :input}
          )
        ],
        output: Ref.result("failure")
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
