defmodule JidoTest.ExecFlowTest do
  use JidoTest.ActionCase, async: false

  require Runic

  alias Jido.Exec
  alias Jido.Exec.Result
  alias Jido.Flow
  alias JidoTest.TestActions.FlowFunctions
  alias JidoTest.TestActions.{Add, Double, Fail, Flaky, Slow, SumJoined}
  alias Runic.Workflow

  test "runs a single-step flow" do
    flow = Flow.new(:single) |> Flow.step(:add, Add, params: %{amount: 4})

    assert {:ok, %Result{workflow: workflow} = result} = Exec.run(flow, %{value: 2})
    assert Workflow.raw_productions(workflow, :add) == [%{value: 6}]

    assert %{
             total_nodes: 1,
             facts_produced: facts_produced,
             satisfied?: true,
             productions: 1
           } = Exec.summary(result)

    assert facts_produced > 0
    assert Flow.node_map(flow).add.action == Add
    assert Exec.results(workflow, raw: true) == [%{value: 6}]
    assert Exec.results(workflow).add == [%{value: 6}]
  end

  test "runs a linear flow across multiple dispatch generations" do
    flow =
      Flow.new(:linear)
      |> Flow.step(:add, Add, params: %{amount: 1})
      |> Flow.step(:double, Double, after: :add)
      |> Flow.step(:add_again, Add, params: %{amount: 3}, after: :double)

    assert {:ok, %Result{workflow: workflow}} = Exec.run(flow, %{value: 2})
    assert Workflow.raw_productions(workflow, :add_again) == [%{value: 9}]
  end

  test "runs fan-in dependencies" do
    flow =
      Flow.new(:fan_in)
      |> Flow.step(:add_one, Add, params: %{amount: 1})
      |> Flow.step(:add_two, Add, params: %{amount: 2})
      |> Flow.step(:sum, SumJoined, after: [:add_one, :add_two])

    assert {:ok, %Result{workflow: workflow}} = Exec.run(flow, %{value: 2})
    assert Workflow.raw_productions(workflow, :sum) == [%{value: 7}]
  end

  test "returns a structured error for failed actions" do
    flow = Flow.new(:fail) |> Flow.step(:fail, Fail)

    assert {:error,
            %Result{status: :error, error: %Jido.Action.Error.ExecutionFailureError{} = error}} =
             silence_logger(fn ->
               Exec.run(flow, %{})
             end)

    assert error.message == "flow runnable failed"
    assert error.details.node == :fail
  end

  test "uses Runic retry policy inside flow steps" do
    key = System.unique_integer([:positive])
    term_key = {Flaky, key}
    :persistent_term.erase(term_key)

    try do
      flow =
        Flow.new(:retry)
        |> Flow.step(:flaky, Flaky)
        |> Flow.policy(:flaky, %{max_retries: 1, backoff: :none})

      assert {:ok, %Result{workflow: workflow}} =
               silence_logger(fn ->
                 Exec.run(flow, %{key: key})
               end)

      assert Workflow.raw_productions(workflow, :flaky) == [%{attempts: 2}]
    after
      :persistent_term.erase(term_key)
    end
  end

  test "uses Runic timeout policy inside flow steps" do
    flow =
      Flow.new(:timeout)
      |> Flow.step(:slow, Slow)
      |> Flow.policy(:slow, %{timeout_ms: 10, max_retries: 0, backoff: :none})

    started_at = System.monotonic_time(:millisecond)

    assert {:error,
            %Result{status: :error, error: %Jido.Action.Error.ExecutionFailureError{} = error}} =
             silence_logger(fn ->
               Exec.run(flow, %{})
             end)

    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    assert elapsed_ms < 150
    assert error.message == "flow runnable failed"
    assert error.details.node == :slow
    assert error.details.reason == {:timeout, 10}
  end

  test "returns a structured error when max_cycles is exceeded" do
    flow =
      Flow.new(:bounded)
      |> Flow.step(:add, Add)
      |> Flow.step(:double, Double, after: :add)

    assert {:error,
            %Result{
              status: :max_cycles,
              error: %Jido.Action.Error.ExecutionFailureError{} = error
            }} =
             Exec.run(flow, %{value: 1}, max_cycles: 1)

    assert error.message == "flow exceeded max dispatch cycles"
    assert error.details.max_cycles == 1
  end

  test "stateful components preserve state across repeated runtime resumes" do
    flow =
      Flow.new(:stateful)
      |> Flow.accumulate(:counter, 0, {FlowFunctions, :sum})

    assert {:ok, %Result{workflow: workflow}} = Exec.run(flow, 2)
    assert 2 in Workflow.raw_productions(workflow, :counter)

    assert {:ok, %Result{workflow: workflow}} =
             workflow
             |> Flow.from_workflow()
             |> Exec.run(3)

    assert 5 in Workflow.raw_productions(workflow, :counter)
  end

  test "bounded state-machine loop reaches its stop condition" do
    machine =
      Runic.state_machine(
        name: :counter_machine,
        init: 0,
        reducer: fn
          :tick, state -> min(state + 1, 3)
          :done, state -> state
        end,
        reactors: [
          done: fn 3 -> :done end
        ]
      )

    flow =
      Workflow.new(:machine)
      |> Workflow.add(machine)
      |> Flow.from_workflow()

    assert {:ok, %Result{workflow: workflow}} = Exec.run(flow, :tick)
    assert {:ok, %Result{workflow: workflow}} = Exec.run(Flow.from_workflow(workflow), :tick)
    assert {:ok, %Result{workflow: workflow}} = Exec.run(Flow.from_workflow(workflow), :tick)

    assert :done in Workflow.raw_productions(workflow)
  end
end
