defmodule JidoActionTest.Flow.ErrorTest do
  use ExUnit.Case, async: true

  alias Jido.Action.Error, as: ActionError
  alias Jido.Flow.Error

  describe "constructors" do
    test "creates Flow-owned Splode errors" do
      definition = Error.validation_error("bad definition", path: [:components, 0])
      invalid_execution = Error.invalid_execution_error("not ready", runnable_id: 12)
      execution = Error.execution_error("failed", phase: :runic_execution)
      internal = Error.internal_error("compiler defect", phase: :flow_compilation)

      assert %Error.InvalidDefinitionError{class: :invalid} = definition
      assert %Error.InvalidExecutionError{class: :invalid} = invalid_execution
      assert %Error.ExecutionFailureError{class: :execution} = execution
      assert %Error.InternalError{class: :internal} = internal

      assert Error.splode_error?(definition)
      assert Error.splode_error?(invalid_execution)
      assert Error.splode_error?(execution)
      assert Error.splode_error?(internal)
    end

    test "normalizes constructor details" do
      assert %{details: %{path: [:output]}} =
               Error.validation_error("bad definition", path: [:output])

      assert %{details: %{}} = Error.execution_error("bad details", [:not_keyword])
      assert %{details: %{}} = Error.internal_error("bad details", :not_a_map)
    end
  end

  describe "Action error alignment" do
    test "merges Action failures without changing the leaf error" do
      action_error = ActionError.execution_error("action failed", retry: false)

      assert %Error.Execution{errors: [merged]} = Error.to_class([action_error, action_error])
      assert merged.__struct__ == action_error.__struct__
      assert merged.message == action_error.message
    end

    test "serializes Action errors through the Action error contract" do
      action_error = ActionError.validation_error("bad action input", field: :value)

      assert Error.to_map(action_error) == ActionError.to_map(action_error)
      refute Error.retryable?(action_error)
    end
  end

  describe "Flow execution failures" do
    test "keeps native runnable failure details in a stable map" do
      action_error = ActionError.execution_error("action failed", retry: false)

      error =
        Error.flow_failure("checkout", [
          %{node: "charge", runnable_id: 21, error: action_error},
          %{node: "notify", runnable_id: 22, error: RuntimeError.exception("offline")}
        ])

      assert %Error.ExecutionFailureError{
               flow: "checkout",
               failures: [_, _]
             } = error

      assert %{
               type: :flow_execution_error,
               message: "Flow \"checkout\" failed in 2 runnables",
               retryable?: false,
               details: %{flow: "checkout", failures: failures}
             } = Error.to_map(error)

      assert [
               %{
                 node: "charge",
                 runnable_id: 21,
                 error: %{type: :execution_error, retryable?: false}
               },
               %{
                 node: "notify",
                 runnable_id: 22,
                 error: %{type: :execution_error, retryable?: false}
               }
             ] = failures

      refute Error.retryable?(error)
      assert is_binary(JSON.encode!(error))
    end

    test "uses an explicit retry value only when one is present" do
      assert Error.retryable?(Error.execution_error("temporary", retry: true))
      refute Error.retryable?(Error.execution_error("permanent"))
    end
  end

  describe "stable maps and JSON" do
    test "serializes each Flow leaf and Splode class" do
      definition = Error.validation_error("bad definition", field: :output)
      invalid_execution = Error.invalid_execution_error("not ready", runnable_id: 12)
      execution = Error.execution_error("failed", phase: :runic_execution)
      internal = Error.internal_error("compiler defect", phase: :flow_compilation)

      invalid_class =
        Error.to_class([
          definition,
          Error.validation_error("second bad definition", field: :components)
        ])

      execution_class =
        Error.to_class([
          execution,
          Error.execution_error("second failure", phase: :flow_output)
        ])

      internal_class =
        Error.to_class([
          internal,
          Error.internal_error("second defect", phase: :flow_materialization)
        ])

      unknown = Error.Internal.UnknownError.exception(error: :unknown_flow_failure)
      binary_unknown = Error.Internal.UnknownError.exception(error: "unknown flow failure")
      tuple_unknown = Error.Internal.UnknownError.exception(error: {:unknown, :flow_failure})
      message_unknown = Error.Internal.UnknownError.exception(message: "explicit failure")

      assert %Error.Invalid{} = invalid_class
      assert %Error.Execution{} = execution_class
      assert %Error.Internal{} = internal_class
      assert Exception.message(unknown) == "unknown_flow_failure"
      assert Exception.message(binary_unknown) == "unknown flow failure"
      assert Exception.message(tuple_unknown) == "{:unknown, :flow_failure}"
      assert Exception.message(message_unknown) == "explicit failure"

      errors = [
        definition,
        invalid_execution,
        execution,
        internal,
        invalid_class,
        execution_class,
        internal_class,
        unknown
      ]

      for error <- errors do
        assert %{type: type, message: message, details: details, retryable?: retryable?} =
                 Error.to_map(error)

        assert is_atom(type)
        assert is_binary(message)
        assert is_map(details)
        assert is_boolean(retryable?)
        assert is_binary(JSON.encode!(error))
        assert Error.owned?(error)
        refute Error.retryable?(error)
      end
    end

    test "accepts error tuples and delegates unsupported values" do
      error = Error.invalid_execution_error("not ready")
      assert Error.to_map({:error, error}) == Error.to_map(error)
      assert Error.to_map({:error, error, %{effect: :none}}) == Error.to_map(error)
      refute Error.retryable?({:error, error})
      refute Error.retryable?({:error, error, %{effect: :none}})

      assert Error.to_map(:foreign_failure) == ActionError.to_map(:foreign_failure)
      refute Error.owned?(:foreign_failure)
    end
  end
end
