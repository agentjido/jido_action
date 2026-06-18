defmodule JidoTest.ExecActionBoundaryTest do
  use JidoTest.ActionCase, async: false

  import ExUnit.CaptureIO

  alias Jido.Action.Output
  alias Jido.Exec
  alias Jido.Exec.Result
  alias Jido.Flow

  alias JidoTest.TestActions.{
    ErrorAction,
    IOAction,
    KilledAction,
    OpaqueOutputWithDirective,
    RawOutputAction,
    StreamingAction
  }

  describe "action invocation boundary" do
    test "rejects non-tuple action return values without running output validation" do
      module = unique_module("WeirdReturnAction")

      create_module(
        module,
        quote do
          use Jido.Action,
            name: "weird_return_action",
            schema: Zoi.object(%{value: Zoi.any()}),
            output_schema: Zoi.object(%{required: Zoi.string()})

          @impl true
          @dialyzer {:nowarn_function, run: 2}
          def run(%{value: value}, _context), do: value
        end
      )

      for value <- [:ok, "result", %{value: 1}, [1, 2, 3]] do
        flow = Flow.from_action(module, %{value: value}, name: :weird_return)

        assert {:error,
                %Result{
                  status: :error,
                  error: %Jido.Action.Error.ExecutionFailureError{} = error
                }} =
                 silence_logger(fn ->
                   Exec.run(flow, %{})
                 end)

        assert error.details.node == :weird_return
        assert %Jido.Action.Error.ExecutionFailureError{} = reason = error.details.reason
        assert reason.message == "unexpected action return shape"
        assert reason.details.value == value
      end
    end

    test "contains thrown values from actions" do
      flow = Flow.from_action(ErrorAction, %{error_type: :throw}, name: :throwing_action)

      assert {:error, %Result{status: :error, error: error}} =
               silence_logger(fn ->
                 Exec.run(flow, %{})
               end)

      assert error.details.node == :throwing_action
      assert %Jido.Action.Error.ExecutionFailureError{} = reason = error.details.reason
      assert reason.message == "action exited during invocation"
      assert reason.details.kind == :throw
      assert reason.details.reason == "Action threw an error"
    end

    test "contains untrappable action exits without taking down the caller" do
      flow = Flow.from_action(KilledAction, %{}, name: :killed_action)

      assert {:error, %Result{status: :error, error: error}} =
               silence_logger(fn ->
                 Exec.run(flow, %{})
               end)

      assert error.details.node == :killed_action
      assert %Jido.Action.Error.ExecutionFailureError{} = reason = error.details.reason
      assert reason.message == "runnable execution exited"
      assert reason.details.kind == :exit
      assert reason.details.reason == :killed
    end

    test "contains untrappable action exits from timeout-isolated policy tasks" do
      flow =
        KilledAction
        |> Flow.from_action(%{}, name: :killed_action)
        |> Flow.policy(:killed_action, %{timeout_ms: 1_000})

      assert {:error, %Result{status: :error, error: error}} =
               silence_logger(fn ->
                 Exec.run(flow, %{})
               end)

      assert error.details.node == :killed_action
      assert %Jido.Action.Error.ExecutionFailureError{} = reason = error.details.reason
      assert reason.message == "runnable execution exited"
      assert reason.details.kind == :exit
      assert reason.details.reason == :killed
    end

    test "streams survive flow execution and remain lazy" do
      flow =
        Flow.from_action(StreamingAction, %{chunk_size: 2, total_items: 10}, name: :streaming)

      assert {:ok, %Result{} = result} = Exec.run(flow, %{})
      assert [%{stream: stream}] = result.results.streaming
      assert %Stream{} = stream
      assert Enum.to_list(stream) == [3, 7, 11, 15, 19]
    end

    test "explicit abnormal outputs are returned unchanged in Exec results" do
      assert {:ok, %Result{} = result} = Exec.run(RawOutputAction, %{})

      assert Exec.results(result).raw_output_action == [
               %Output{kind: :raw, value: [1, 2, 3], meta: %{source: :test}}
             ]
    end

    test "directive-bearing abnormal outputs preserve result and directives" do
      assert {:ok, %Result{} = result} = Exec.run(OpaqueOutputWithDirective, %{})

      assert [%Output{kind: :opaque, value: {:external, pid}, meta: %{}}] =
               Exec.results(result).opaque_output_with_directive

      assert is_pid(pid)

      assert [
               %{
                 step: :opaque_output_with_directive,
                 status: :ok,
                 directives: %{next: :flow},
                 fact_hash: fact_hash
               }
             ] = result.directives

      refute is_nil(fact_hash)
    end

    test "routes action IO to the caller while executing under timeout policy" do
      flow =
        IOAction
        |> Flow.from_action(%{input: "test output", operation: :puts}, name: :io_action)
        |> Flow.policy(:io_action, %{timeout_ms: 1_000})

      io =
        capture_io(fn ->
          assert {:ok, %Result{} = result} = Exec.run(flow, %{})
          assert result.results.io_action == [%{input: "test output"}]
        end)

      assert io == "test output\n"
    end
  end
end
