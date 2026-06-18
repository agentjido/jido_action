defmodule JidoTest.ExecFlowTest do
  use JidoTest.ActionCase, async: false

  require Runic

  alias Jido.Exec
  alias Jido.Exec.Result
  alias Jido.Flow
  alias Runic.Workflow

  defmodule Add do
    use Jido.Action,
      name: "runtime_add",
      schema:
        Zoi.object(%{
          value: Zoi.integer(),
          amount: Zoi.integer() |> Zoi.default(1)
        }),
      output_schema: Zoi.object(%{value: Zoi.integer()})

    def run(%{value: value, amount: amount}, _context), do: {:ok, %{value: value + amount}}
  end

  defmodule Double do
    use Jido.Action,
      name: "runtime_double",
      schema: Zoi.object(%{value: Zoi.integer()}),
      output_schema: Zoi.object(%{value: Zoi.integer()})

    def run(%{value: value}, _context), do: {:ok, %{value: value * 2}}
  end

  defmodule SumJoined do
    use Jido.Action,
      name: "runtime_sum_joined",
      schema: Zoi.object(%{input: Zoi.list(Zoi.map(Zoi.any(), Zoi.any()))}),
      output_schema: Zoi.object(%{value: Zoi.integer()})

    def run(%{input: values}, _context) do
      total = Enum.reduce(values, 0, fn %{value: value}, acc -> acc + value end)
      {:ok, %{value: total}}
    end
  end

  defmodule Fail do
    use Jido.Action,
      name: "runtime_fail",
      schema: Zoi.object(%{}),
      output_schema: Zoi.object(%{})

    def run(_params, _context), do: {:error, "boom"}
  end

  defmodule Flaky do
    use Jido.Action,
      name: "runtime_flaky",
      schema: Zoi.object(%{key: Zoi.any()}),
      output_schema: Zoi.object(%{attempts: Zoi.integer()})

    def run(%{key: key}, _context) do
      attempts = :persistent_term.get({__MODULE__, key}, 0) + 1
      :persistent_term.put({__MODULE__, key}, attempts)

      if attempts < 2 do
        {:error, :transient_error}
      else
        {:ok, %{attempts: attempts}}
      end
    end
  end

  defmodule Slow do
    use Jido.Action,
      name: "runtime_slow",
      schema: Zoi.object(%{}),
      output_schema: Zoi.object(%{done: Zoi.boolean()})

    def run(_params, _context) do
      Process.sleep(200)
      {:ok, %{done: true}}
    end
  end

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
    counter = Runic.accumulator(0, fn value, state -> state + value end, name: :counter)
    flow = Flow.new(:stateful) |> Flow.component(:counter, counter)

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

    flow = Flow.new(:machine) |> Flow.component(:counter_machine, machine)

    assert {:ok, %Result{workflow: workflow}} = Exec.run(flow, :tick)
    assert {:ok, %Result{workflow: workflow}} = Exec.run(Flow.from_workflow(workflow), :tick)
    assert {:ok, %Result{workflow: workflow}} = Exec.run(Flow.from_workflow(workflow), :tick)

    assert :done in Workflow.raw_productions(workflow)
  end
end
