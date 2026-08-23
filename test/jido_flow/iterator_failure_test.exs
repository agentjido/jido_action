defmodule Jido.Flow.IteratorFailureTest do
  use ExUnit.Case, async: true

  @moduletag capture_log: true

  alias Jido.Action.Error
  alias Jido.Action.Error.{ExecutionFailureError, InternalError, InvalidInputError}
  alias Jido.Exec
  alias Jido.Exec.NodeResult
  alias Jido.Flow.Ref
  alias JidoTest.IteratorFixtures

  alias JidoTest.IteratorFixtures.{
    BrokenFlow,
    FailsSecond,
    Increment,
    InvalidOutput,
    RetryableFailure,
    ReturnedException
  }

  describe "bounded Iterator failures" do
    test "keeps prior effects but returns no partial State after a body failure" do
      flow =
        IteratorFixtures.iterator_flow(
          action: FailsSecond,
          initial: %{count: Ref.value(0)},
          completion: IteratorFixtures.eq(Ref.value(false), Ref.value(true)),
          max_iterations: 3
        )

      assert {:error,
              %ExecutionFailureError{
                message: "second body failed",
                details: %{
                  phase: :iterate_body_execution,
                  node: "count",
                  target: FailsSecond,
                  iteration_index: 1,
                  state_revision: 1,
                  retry: false
                }
              } = error} = Exec.run(flow, %{}, %{test_pid: self()})

      assert_receive {FailsSecond, 0}
      assert_receive {FailsSecond, 1}
      refute Map.has_key?(error.details, :state)
      refute Map.has_key?(error.details, :output)
    end

    test "preserves an explicit target retry policy without target error details" do
      flow =
        IteratorFixtures.iterator_flow(
          action: RetryableFailure,
          initial: %{count: Ref.value(0)},
          completion: IteratorFixtures.eq(Ref.value(false), Ref.value(true)),
          max_iterations: 1
        )

      assert {:error,
              %ExecutionFailureError{
                message: "retryable body failed",
                details: %{
                  phase: :iterate_body_execution,
                  node: "count",
                  target: RetryableFailure,
                  iteration_index: 0,
                  state_revision: 0,
                  retry: true
                }
              } = error} = Exec.run(flow, %{}, %{})

      assert Error.retryable?(error)
      refute Map.has_key?(error.details, :rejected_payload)
    end

    test "adds bounded ownership details to a returned standard exception" do
      flow =
        IteratorFixtures.iterator_flow(
          action: ReturnedException,
          initial: %{count: Ref.value(0)},
          completion: IteratorFixtures.eq(Ref.value(false), Ref.value(true)),
          max_iterations: 1
        )

      assert {:error, %RuntimeError{message: "returned body exception"} = error} =
               Exec.run(flow, %{}, %{})

      assert %{
               phase: :iterate_body_execution,
               node: "count",
               target: ReturnedException,
               iteration_index: 0,
               state_revision: 0,
               retry: false
             } = IteratorFixtures.error_details(error)
    end

    test "preserves bounded body input and output validation failures" do
      bad_input =
        IteratorFixtures.iterator_flow(
          input: %{count: Ref.value("bad"), index: Ref.iteration_index()},
          initial: %{count: Ref.value(0)},
          completion: IteratorFixtures.eq(Ref.value(false), Ref.value(true)),
          max_iterations: 1
        )

      assert {:error,
              %InvalidInputError{
                details: %{
                  phase: :iterate_body_input,
                  node: "count",
                  target: Increment,
                  iteration_index: 0,
                  state_revision: 0,
                  retry: false
                }
              }} = Exec.run(bad_input, %{}, %{})

      bad_output =
        IteratorFixtures.iterator_flow(
          action: InvalidOutput,
          initial: %{count: Ref.value(0)},
          completion: IteratorFixtures.eq(Ref.value(false), Ref.value(true)),
          max_iterations: 1
        )

      assert {:error,
              %InvalidInputError{
                details: %{
                  phase: :iterate_body_output,
                  node: "count",
                  target: InvalidOutput,
                  iteration_index: 0,
                  state_revision: 0,
                  retry: false
                }
              }} = Exec.run(bad_output, %{}, %{})
    end

    test "normalizes an unexpected body adapter defect" do
      flow =
        IteratorFixtures.iterator_flow(
          action: BrokenFlow,
          initial: %{count: Ref.value(0)},
          completion: IteratorFixtures.eq(Ref.value(false), Ref.value(true)),
          max_iterations: 1
        )

      assert {:error,
              %InternalError{
                message: "flow iterator adapter failed",
                details: %{
                  phase: :iterate_internal,
                  node: "count",
                  iteration_index: 0,
                  state_revision: 0,
                  error_type: RuntimeError,
                  retry: false
                }
              }} = Exec.run(flow, %{}, %{})
    end

    test "rejects invalid completion operands before the first body" do
      flow =
        IteratorFixtures.iterator_flow(
          initial: %{count: Ref.value(0)},
          completion: IteratorFixtures.gte(Ref.state(), Ref.value(1)),
          max_iterations: 1
        )

      assert {:error,
              %ExecutionFailureError{
                message: "invalid iterator completion condition operands",
                details: %{
                  phase: :iterate_completion,
                  node: "count",
                  operator: :gte,
                  reason: :invalid_ordering_operands,
                  left_type: :map,
                  right_type: :number,
                  iterations: 0,
                  retry: false
                }
              }} = Exec.run(flow, %{}, %{test_pid: self()})

      refute_received {Increment, _index}
    end

    test "reports a post-commit completion failure at the committed iteration count" do
      flow =
        IteratorFixtures.iterator_flow(
          initial: %{count: Ref.value(0), guard: Ref.value(-1)},
          update: %{count: Ref.body_result(:count), guard: Ref.value(%{})},
          completion: IteratorFixtures.gte(Ref.state(:guard), Ref.value(0)),
          max_iterations: 1
        )

      assert {:ok, execution} = Exec.start(flow)

      assert {:ok,
              %NodeResult{
                status: :error,
                output: nil,
                error: %ExecutionFailureError{
                  message: "invalid iterator completion condition operands",
                  details: %{
                    phase: :iterate_completion,
                    node: "count",
                    operator: :gte,
                    reason: :invalid_ordering_operands,
                    left_type: :map,
                    right_type: :number,
                    iterations: 1,
                    retry: false
                  }
                }
              }, failed_execution} = Exec.step(execution)

      assert failed_execution.revision == 1
      assert Exec.status(failed_execution) == :failed
    end
  end
end
