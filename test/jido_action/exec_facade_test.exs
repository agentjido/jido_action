defmodule JidoTest.ExecFacadeTest do
  use JidoTest.ActionCase, async: false

  import ExUnit.CaptureIO

  alias Jido.Exec
  alias Jido.Exec.Result
  alias Jido.Flow
  alias JidoTest.TestActions.{Add, Flaky}
  alias JidoTest.TestActions.ErrorAction
  alias JidoTest.TestActions.IOAction
  alias JidoTest.TestActions.KilledAction
  alias JidoTest.TestActions.StreamingAction
  alias Runic.Workflow.RunnableCompleted
  alias Runic.Workflow.RunnableDispatched
  alias Runic.Workflow

  describe "run/3 facade dispatch" do
    test "flow execution returns a Jido.Exec.Result" do
      flow = Flow.new(:facade_flow) |> Flow.step(:add, Add, params: %{amount: 2})

      assert {:ok, %Result{} = result} = Exec.run(flow, %{value: 3})
      assert result.status == :ok
      assert Exec.results(result).add == [%{value: 5}]
    end

    test "raw Runic workflow execution returns a Jido.Exec.Result" do
      workflow =
        Flow.new(:facade_workflow)
        |> Flow.step(:add, Add, params: %{amount: 2})
        |> Flow.to_workflow()

      assert {:ok, %Result{} = result} = Exec.run(workflow, %{value: 3})
      assert result.status == :ok
      assert Exec.results(result).add == [%{value: 5}]
    end

    test "direct action execution is not supported" do
      assert {:error, %Jido.Action.Error.InvalidInputError{} = error} =
               Exec.run(Add, %{value: 3, amount: 2})

      assert Exception.message(error) =~ "expected a Jido.Flow or Runic.Workflow"
    end
  end

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
      flow = Flow.from_action(ErrorAction, %{type: :throw}, name: :throwing_action)

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

  describe "result schema" do
    test "result construction is schema validated" do
      workflow = Workflow.new(:schema_result)

      result = Result.new(workflow, :ok, results: %{})

      assert %Result{status: :ok, results: %{}, events: [], cycles: 0, error: nil} = result
      assert result.workflow == workflow

      assert_raise ArgumentError, ~r/invalid execution result/, fn ->
        apply(Result, :new, [workflow, :bogus])
      end

      assert_raise ArgumentError, ~r/invalid execution result/, fn ->
        Result.new(workflow, :ok, cycles: -1)
      end
    end
  end

  describe "Runic flow policy integration" do
    test "named flow policy applies without Jido app defaults" do
      with_flaky_key(fn key ->
        flow =
          Flow.new(:workflow_policy)
          |> Flow.step(:flaky, Flaky)
          |> Flow.policy(:flaky, %{max_retries: 0, backoff: :none})

        silence_logger(fn ->
          assert {:error, %Result{status: :error}} = Exec.run(flow, %{key: key})
        end)
      end)
    end

    test "named flow policy can retry a matching component" do
      with_flaky_key(fn key ->
        flow =
          Flow.new(:step_policy)
          |> Flow.step(:flaky, Flaky)
          |> Flow.policy(:flaky, %{max_retries: 1, backoff: :none})

        {:ok, %Result{workflow: workflow}} =
          silence_logger(fn ->
            Exec.run(flow, %{key: key})
          end)

        assert Workflow.raw_productions(workflow, :flaky) == [%{attempts: 2}]
      end)
    end

    test "runtime scheduler_policies override named flow policies" do
      with_flaky_key(fn key ->
        flow =
          Flow.new(:runtime_policy)
          |> Flow.step(:flaky, Flaky)
          |> Flow.policy(:flaky, %{max_retries: 1, backoff: :none})

        silence_logger(fn ->
          assert {:error, %Result{status: :error}} =
                   Exec.run(flow, %{key: key},
                     scheduler_policies: [{:flaky, %{max_retries: 0, backoff: :none}}]
                   )
        end)
      end)
    end

    test "durable step policy exposes Runic runnable lifecycle events" do
      flow =
        Flow.new(:durable_policy)
        |> Flow.step(:add, Add, params: %{amount: 2})
        |> Flow.policy(:add, %{execution_mode: :durable})

      assert {:ok, %Result{} = result} = Exec.run(flow, %{value: 3})

      events = Exec.events(result)
      assert Enum.any?(events, &match?(%RunnableDispatched{}, &1))
      assert Enum.any?(events, &match?(%RunnableCompleted{}, &1))
    end
  end

  defp with_flaky_key(fun) do
    key = System.unique_integer([:positive])
    term_key = {Flaky, key}
    :persistent_term.erase(term_key)

    try do
      fun.(key)
    after
      :persistent_term.erase(term_key)
    end
  end
end
