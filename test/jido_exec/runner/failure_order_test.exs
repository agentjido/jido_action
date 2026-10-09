defmodule Jido.Exec.Runner.FailureOrderTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true

  alias Jido.Exec
  alias Runic.Runner

  defmodule Fail do
    use Jido.Action, name: "ordered_failure"

    @impl true
    def run(%{label: label}, context) do
      if observer = context[:observer] do
        send(Process.whereis(observer), {:started, label, self()})
        receive do: (:release -> :ok)
      end

      {:error, label}
    end
  end

  defmodule Parent do
    use Jido.Action, name: "ordered_parent"
    @impl true
    def run(%{label: label}, context) do
      if context[:block] == label do
        send(Process.whereis(context.observer), {:blocked_parent, self()})
        receive do: (:release -> :ok)
      end

      {:ok, %{label: label}}
    end
  end

  setup do
    observer = :"failure_order_#{System.unique_integer([:positive])}"
    Process.register(self(), observer)

    flow =
      Jido.Flow.new!(%{
        name: "ordered_failure_flow",
        components: [
          %{kind: :step, name: "a", action: Fail, params: %{label: "a"}},
          %{kind: :step, name: "b", action: Fail, params: %{label: "b"}}
        ],
        output: %{a: Jido.Flow.Ref.result("a"), b: Jido.Flow.Ref.result("b")}
      })

    {:error, serial} = Exec.run(flow)
    %{observer: observer, flow: flow, expected: Exception.message(serial)}
  end

  test "immediate failure selection ignores reversed completion", ctx do
    caller =
      Task.async(fn -> Exec.run(ctx.flow, %{}, %{observer: ctx.observer}, max_concurrency: 2) end)

    on_exit(fn -> if Process.alive?(caller.pid), do: Process.exit(caller.pid, :kill) end)
    tasks = started_tasks()
    other = if ctx.expected == "a", do: "b", else: "a"
    release_and_confirm(Map.fetch!(tasks, other))
    send(Map.fetch!(tasks, ctx.expected), :release)
    assert {:error, error} = Task.await(caller, 2_000)
    assert Exception.message(error) == ctx.expected
  end

  test "managed selection matches serial while its event log keeps completion order", ctx do
    runner = :"ordered_runner_#{System.unique_integer([:positive])}"
    start_supervised!({Runner, name: runner})
    owner = self()

    {:ok, _} =
      Exec.start(runner, :ordered, ctx.flow, %{}, %{observer: ctx.observer},
        max_concurrency: 2,
        on_complete: fn _, workflow -> send(owner, {:completed, workflow}) end
      )

    tasks = started_tasks()
    other = if ctx.expected == "a", do: "b", else: "a"
    release_and_confirm(Map.fetch!(tasks, other))
    send(Map.fetch!(tasks, ctx.expected), :release)
    assert_receive {:completed, workflow}, 2_000

    errors =
      for %Runic.Workflow.RunnableFailed{error: error} <- workflow.runnable_events,
          do: Exception.message(error)

    assert errors == [other, ctx.expected]
    assert {:error, error} = Exec.result(workflow)
    assert Exception.message(error) == ctx.expected
  end

  test "managed stable admission waits for parent work before admitting failing children", ctx do
    flow =
      Jido.Flow.new!(%{
        name: "ordered_parent_frontier",
        components: [
          %{kind: :step, name: "a_parent", action: Parent, params: %{label: "a"}},
          %{kind: :step, name: "b_parent", action: Parent, params: %{label: "b"}},
          %{
            kind: :step,
            name: "a_fail",
            action: Fail,
            params: %{label: "a"},
            needs: ["a_parent"]
          },
          %{kind: :step, name: "b_fail", action: Fail, params: %{label: "b"}, needs: ["b_parent"]}
        ],
        output: %{a: Jido.Flow.Ref.result("a_fail"), b: Jido.Flow.Ref.result("b_fail")}
      })

    {:error, serial} = Exec.run(flow)
    expected = Exception.message(serial)
    other = if expected == "a", do: "b", else: "a"
    runner = :"frontier_runner_#{System.unique_integer([:positive])}"
    start_supervised!({Runner, name: runner})
    owner = self()

    {:ok, _} =
      Exec.start(runner, :frontier, flow, %{}, %{observer: ctx.observer, block: expected},
        max_concurrency: 2,
        hooks: [
          on_dispatch: fn runnable, _ ->
            if String.ends_with?(runnable.node.name, "_fail"), do: send(owner, :child_admitted)
          end,
          on_complete: fn runnable, _, _ ->
            if runnable.node.name == other <> "_parent", do: send(owner, :other_parent_done)
          end
        ],
        on_complete: fn _, workflow -> send(owner, {:frontier_done, workflow}) end
      )

    assert_receive {:blocked_parent, parent}, 2_000
    assert_receive :other_parent_done, 2_000
    assert {:ok, %{status: :open, active_units: 1}} = Runner.admission_status(runner, :frontier)
    refute_received :child_admitted
    send(parent, :release)
    # Child Actions have an observer gate; release each after admission.
    tasks = started_tasks()
    Enum.each(tasks, fn {_, pid} -> send(pid, :release) end)
    assert_receive {:frontier_done, workflow}, 2_000
    assert {:error, error} = Exec.result(workflow)
    assert Exception.message(error) == expected
  end

  defp started_tasks do
    assert_receive {:started, first, first_pid}, 2_000
    assert_receive {:started, second, second_pid}, 2_000
    %{first => first_pid, second => second_pid}
  end

  defp release_and_confirm(pid) do
    monitor = Process.monitor(pid)
    send(pid, :release)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 2_000
  end
end
