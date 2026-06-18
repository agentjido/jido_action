defmodule JidoTest.ExecRuntimeOptionsTest do
  use JidoTest.ActionCase, async: false

  alias Jido.Exec
  alias Jido.Exec.Result
  alias Jido.Flow
  alias JidoTest.TestActions.{Add, Flaky}
  alias Runic.Workflow
  alias Runic.Workflow.RunnableCompleted
  alias Runic.Workflow.RunnableDispatched
  alias Runic.Workflow.SchedulerPolicy

  describe "runtime options" do
    test "validates run context and max cycle options" do
      flow = Flow.from_action(Add, %{amount: 1}, name: :add)

      assert {:error, %Jido.Action.Error.InvalidInputError{} = error} =
               Exec.run(flow, %{value: 1}, run_context: [])

      assert Exception.message(error) == ":run_context must be a map"
      assert error.details.run_context == []

      assert {:error, %Jido.Action.Error.InvalidInputError{} = error} =
               Exec.run(flow, %{value: 1}, max_cycles: 0)

      assert Exception.message(error) == ":max_cycles must be a positive integer"
      assert error.details.max_cycles == 0
    end

    test "supports checkpoints, deadline options, and explicit Fact input" do
      parent = self()

      flow =
        Flow.new(:option_flow)
        |> Flow.step(:add, Add, params: %{amount: 2})
        |> Flow.step(:again, Add, params: %{amount: 1}, after: :add)

      fact = Runic.Workflow.Fact.new(value: %{value: 3})

      assert {:ok, %Result{} = result} =
               Exec.run(flow, fact,
                 deadline_ms: 1_000,
                 checkpoint: fn workflow ->
                   send(parent, {:checkpoint, Workflow.raw_productions(workflow)})
                 end
               )

      assert Exec.results(result).again == [%{value: 6}]
      assert_receive {:checkpoint, [%{value: 5}]}
      assert_receive {:checkpoint, productions}
      assert %{value: 6} in productions

      deadline_at = System.monotonic_time(:millisecond) + 1_000

      assert {:ok, %Result{} = deadline_result} =
               Exec.run(Add, %{value: 1, amount: 1}, deadline_ms: 1, deadline_at: deadline_at)

      assert Exec.results(deadline_result).add == [%{value: 2}]
    end

    test "accepts scheduler policy structs and keyword runtime overrides" do
      with_flaky_key(fn key ->
        flow =
          Flow.new(:struct_policy)
          |> Flow.step(:flaky, Flaky)
          |> Flow.policy(:flaky, SchedulerPolicy.fast_fail())

        assert {:error, %Result{status: :error}} =
                 silence_logger(fn -> Exec.run(flow, %{key: key}) end)
      end)

      with_flaky_key(fn key ->
        flow =
          Flow.new(:keyword_policy)
          |> Flow.step(:flaky, Flaky)
          |> Flow.policy(:flaky, %{max_retries: 0, backoff: :none})

        assert {:ok, %Result{} = result} =
                 silence_logger(fn ->
                   Exec.run(flow, %{key: key},
                     scheduler_policies: [{:flaky, [max_retries: 1, backoff: :none]}],
                     scheduler_policies_mode: :replace
                   )
                 end)

        assert Exec.results(result).flaky == [%{attempts: 2}]
      end)

      with_flaky_key(fn key ->
        flow = Flow.new(:runtime_struct_policy) |> Flow.step(:flaky, Flaky)

        assert {:error, %Result{status: :error}} =
                 silence_logger(fn ->
                   Exec.run(flow, %{key: key},
                     scheduler_policies: [{:flaky, SchedulerPolicy.fast_fail()}]
                   )
                 end)
      end)
    end

    test "validates scheduler policy option shapes" do
      flow = Flow.from_action(Add, %{amount: 1}, name: :add)

      assert {:error, %Jido.Action.Error.InvalidInputError{} = error} =
               Exec.run(flow, %{value: 1}, scheduler_policies: :bad)

      assert Exception.message(error) == ":scheduler_policies must be a list"
      assert error.details.scheduler_policies == :bad

      assert {:error, %Jido.Action.Error.InvalidInputError{} = error} =
               Exec.run(flow, %{value: 1}, scheduler_policies: [{:add, :bad}])

      assert Exception.message(error) =~
               ":scheduler_policies must be a list of {matcher, policy} tuples"

      assert error.details.scheduler_policies == [{:add, :bad}]

      assert {:error, %Jido.Action.Error.InvalidInputError{} = error} =
               Exec.run(flow, %{value: 1}, scheduler_policies: [:bad_entry])

      assert Exception.message(error) =~
               ":scheduler_policies must be a list of {matcher, policy} tuples"

      assert error.details.scheduler_policies == [:bad_entry]

      assert {:error, %Jido.Action.Error.InvalidInputError{} = error} =
               Exec.step(flow, %{value: 1}, scheduler_policies_mode: :bad_mode)

      assert Exception.message(error) == ":scheduler_policies_mode must be :merge or :replace"
      assert error.details.scheduler_policies_mode == :bad_mode
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
