defmodule Jido.Exec.Runner.NativeOwnershipTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true

  alias Jido.Exec
  alias JidoActionTest.Fixtures.Execution.FailingStore
  alias Runic.Runner

  defmodule Trapped do
    use Jido.Action, name: "native_trapped_action"

    @impl true
    def run(_params, %{observer: observer}) do
      Process.flag(:trap_exit, true)
      owner = Process.whereis(observer)
      send(owner, {:started, self()})
      wait(owner)
    end

    defp wait(owner) do
      receive do
        {:probe, token} ->
          send(owner, {:alive, token})
          wait(owner)

        :release ->
          {:ok, %{released: true}, [:released]}
      end
    end
  end

  defmodule Recover do
    use Jido.Action, name: "native_recover_action"

    @impl true
    def run(_params, %{counter: counter}) do
      attempt = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      if attempt == 1, do: Process.exit(self(), :kill)
      {:ok, %{attempt: attempt}, [:recovered]}
    end
  end

  setup do
    suffix = System.unique_integer([:positive])
    observer = :"native_action_observer_#{suffix}"
    Process.register(self(), observer)
    runner = :"native_action_runner_#{suffix}"
    store = start_supervised!(FailingStore)
    start_supervised!({Runner, name: runner, store: FailingStore, store_opts: [agent: store]})
    %{runner: runner, store: store, observer: observer}
  end

  for operation <- [:stop, :cancel, :worker_death] do
    test "#{operation} stops an Action that traps exits", ctx do
      {:ok, worker} = Exec.start(ctx.runner, :trapped, Trapped, %{}, %{observer: ctx.observer})
      assert_receive {:started, task}, 2_000
      task_ref = Process.monitor(task)
      worker_ref = Process.monitor(worker)

      case unquote(operation) do
        :stop -> assert :ok = Runner.stop(ctx.runner, :trapped, persist: false)
        :cancel -> assert :ok = Runner.cancel(ctx.runner, :trapped)
        :worker_death -> Process.exit(worker, :kill)
      end

      assert_receive {:DOWN, ^task_ref, :process, ^task, _}, 2_000
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}, 2_000
      refute Process.alive?(task)
      refute Runner.lookup(ctx.runner, :trapped) == worker
    end
  end

  test "a failed persistent stop keeps the same Worker and live Action", ctx do
    {:ok, worker} =
      Exec.start(ctx.runner, :persistent, Trapped, %{}, %{observer: ctx.observer},
        checkpoint_strategy: :manual
      )

    assert_receive {:started, task}, 2_000
    task_ref = Process.monitor(task)
    FailingStore.fail(ctx.store, true)

    assert {:error, {:persistence_failed, :storage_unavailable}} =
             Runner.stop(ctx.runner, :persistent, persist: true)

    assert Runner.lookup(ctx.runner, :persistent) == worker
    token = make_ref()
    send(task, {:probe, token})
    assert_receive {:alive, ^token}, 2_000

    FailingStore.fail(ctx.store, false)
    assert :ok = Runner.stop(ctx.runner, :persistent, persist: true)
    assert_receive {:DOWN, ^task_ref, :process, ^task, _}, 2_000
  end

  test "acknowledged uncertainty survives replay and fresh execution resolves it", ctx do
    counter = :"native_action_counter_#{System.unique_integer([:positive])}"
    counter_pid = start_supervised!({Agent, fn -> 0 end}, id: counter)
    Process.register(counter_pid, counter)
    owner = self()
    opts = [on_complete: fn _, _ -> send(owner, :drained) end]

    {:ok, _} = Exec.start(ctx.runner, :recover, Recover, %{}, %{counter: counter}, opts)
    assert_receive :drained, 2_000
    assert {:ok, first} = Runner.get_workflow(ctx.runner, :recover)
    assert {:error, %{details: %{reason: :killed}}} = Exec.result(first)
    assert :ok = Runner.checkpoint(ctx.runner, :recover)
    assert :ok = Runner.stop(ctx.runner, :recover, persist: true)

    {:ok, _} = Exec.resume(ctx.runner, :recover, %{counter: counter}, opts)
    assert_receive :drained, 2_000
    assert Agent.get(counter, & &1) == 2
    assert {:ok, restored} = Runner.get_workflow(ctx.runner, :recover)
    assert {:ok, %{attempt: 2}, [:recovered]} = Exec.result(restored)
    assert Enum.any?(restored.runnable_events, &is_struct(&1, Runic.Workflow.ExecutionUncertain))
    refute Enum.any?(restored.runnable_events, &is_struct(&1, Runic.Workflow.RunnableFailed))
  end
end
