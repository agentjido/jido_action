defmodule Jido.Exec.Runner.StepwiseTest do
  use ExUnit.Case, async: false

  alias Jido.Exec
  alias Jido.Flow
  alias Jido.Flow.Ref
  alias Runic.Workflow
  alias Runic.Workflow.{RunnableCompleted, RunnableFailed}

  defmodule Recorder do
    use Agent

    def start_link(_opts), do: Agent.start_link(fn -> [] end, name: __MODULE__)
    def record(label), do: Agent.update(__MODULE__, &(&1 ++ [label]))
    def entries, do: Agent.get(__MODULE__, & &1)
  end

  defmodule RecordAdd do
    use Jido.Action, name: "stepwise_record_add"

    @impl true
    def run(%{label: label, value: value}, _context) do
      :ok = Recorder.record(label)
      {:ok, %{value: value + 1}}
    end
  end

  defmodule Fail do
    use Jido.Action, name: "stepwise_fail"

    @impl true
    def run(_params, _context) do
      :ok = Recorder.record(:failed)
      {:error, :step_failed}
    end
  end

  setup do
    runner = Module.concat(__MODULE__, Runner)
    start_supervised!(Recorder)
    start_supervised!({Runic.Runner, name: runner})
    %{runner: runner}
  end

  test "automatic dispatch remains the default", %{runner: runner} do
    flow = serial_flow("automatic_stepwise_default")
    execution_id = {:automatic, System.unique_integer([:positive])}

    assert {:ok, _pid} = Exec.start(runner, execution_id, flow, %{value: 0})
    assert {:error, :automatic_dispatch} = Exec.step(runner, execution_id)

    wait_for_result(runner, execution_id, %{value: 2})

    assert Recorder.entries() == [:first, :second]
  end

  test "a caller advances one Runic unit and inspects the workflow until completion", %{
    runner: runner
  } do
    flow = serial_flow("manual_stepwise_flow")
    execution_id = {:manual, System.unique_integer([:positive])}

    assert {:ok, _pid} =
             Exec.start(runner, execution_id, flow, %{value: 0}, %{},
               dispatch_mode: :manual,
               max_concurrency: 1
             )

    assert {3, %Workflow{} = workflow} = step_to_completion(runner, execution_id)
    refute Workflow.is_runnable?(workflow)
    assert Recorder.entries() == [:first, :second]

    assert {:ok, productions} = Runic.Runner.get_results(runner, execution_id)
    assert %{value: 2} in productions
  end

  test "a failed unit returns terminal Runic state and blocks dependent work", %{runner: runner} do
    flow = failure_flow()
    execution_id = {:failure, System.unique_integer([:positive])}

    assert {:ok, _pid} =
             Exec.start(runner, execution_id, flow, %{}, %{}, dispatch_mode: :manual)

    assert {_steps, %Workflow{} = workflow} = step_to_completion(runner, execution_id)

    assert Enum.any?(workflow.runnable_events, fn
             %RunnableFailed{
               error: %Jido.Action.Error.ExecutionFailureError{message: "step_failed"}
             } ->
               true

             _event ->
               false
           end)

    assert Recorder.entries() == [:failed]
  end

  test "manual execution resumes from durable Runic state", %{runner: runner} do
    flow = serial_flow("durable_stepwise_flow")
    execution_id = {:durable_manual, System.unique_integer([:positive])}

    assert {:ok, _pid} =
             Exec.start(runner, execution_id, flow, %{value: 0}, %{},
               dispatch_mode: :manual,
               max_concurrency: 1,
               checkpoint_strategy: :every_cycle
             )

    assert {:ok, %Workflow{} = workflow} = step_when_ready(runner, execution_id)
    first = Workflow.get_component(workflow, "first")
    wait_for_node(runner, execution_id, first.hash)
    assert Recorder.entries() == [:first]

    assert :ok = Runic.Runner.checkpoint(runner, execution_id)
    assert :ok = Runic.Runner.stop(runner, execution_id, persist: true)

    assert {:ok, _pid} =
             Runic.Runner.resume(runner, execution_id,
               dispatch_mode: :manual,
               executor: Jido.Exec.Runner.TaskExecutor,
               executor_opts: [task_supervisor: Module.concat(runner, TaskSupervisor)],
               max_concurrency: 1
             )

    assert {_steps, %Workflow{}} = step_to_completion(runner, execution_id)
    assert Recorder.entries() == [:first, :second]

    assert {:ok, productions} = Runic.Runner.get_results(runner, execution_id)
    assert %{value: 2} in productions
  end

  defp serial_flow(name) do
    Flow.new!(%{
      name: name,
      components: [
        %{
          kind: :step,
          name: "first",
          action: RecordAdd,
          params: %{label: :first, value: Ref.input(:value)}
        },
        %{
          kind: :step,
          name: "second",
          action: RecordAdd,
          params: %{label: :second, value: Ref.result("first", :value)}
        }
      ],
      output: Ref.result("second")
    })
  end

  defp failure_flow do
    Flow.new!(%{
      name: "manual_stepwise_failure",
      components: [
        %{kind: :step, name: "fail", action: Fail, params: %{}},
        %{
          kind: :step,
          name: "blocked",
          action: RecordAdd,
          params: %{label: :blocked, value: Ref.result("fail", :value)}
        }
      ],
      output: Ref.result("blocked")
    })
  end

  defp step_to_completion(runner, execution_id, count \\ 0) do
    case step_when_ready(runner, execution_id) do
      {:ok, %Workflow{}} -> step_to_completion(runner, execution_id, count + 1)
      {:complete, %Workflow{} = workflow} -> {count, workflow}
    end
  end

  defp step_when_ready(runner, execution_id, attempts \\ 200)

  defp step_when_ready(_runner, _execution_id, 0),
    do: flunk("Runic step did not become ready")

  defp step_when_ready(runner, execution_id, attempts) do
    case Exec.step(runner, execution_id) do
      {:error, :busy} ->
        Process.sleep(10)
        step_when_ready(runner, execution_id, attempts - 1)

      result ->
        result
    end
  end

  defp wait_for_node(runner, execution_id, node_hash) do
    wait_until(fn ->
      with {:ok, workflow} <- Runic.Runner.get_workflow(runner, execution_id) do
        completed_node?(workflow, node_hash)
      else
        _other -> false
      end
    end)
  end

  defp completed_node?(workflow, node_hash) do
    Enum.any?(workflow.runnable_events, fn
      %RunnableCompleted{node_hash: ^node_hash} -> true
      _event -> false
    end)
  end

  defp wait_for_result(runner, execution_id, expected) do
    wait_until(fn ->
      case Runic.Runner.get_results(runner, execution_id) do
        {:ok, productions} -> expected in productions
        {:error, _reason} -> false
      end
    end)
  end

  defp wait_until(condition, attempts \\ 200)
  defp wait_until(_condition, 0), do: flunk("condition did not become true")

  defp wait_until(condition, attempts) do
    if condition.() do
      :ok
    else
      Process.sleep(10)
      wait_until(condition, attempts - 1)
    end
  end
end
