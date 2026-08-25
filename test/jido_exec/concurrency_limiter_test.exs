defmodule JidoActionTest.Exec.ConcurrencyLimiterTest do
  use ExUnit.Case, async: false

  alias Jido.Exec.ConcurrencyLimiter
  alias Jido.Exec.OrderedTaskRunner
  alias Jido.{Exec, Flow}
  alias Jido.Flow.{Ref, Step}
  alias JidoActionTest.Fixtures.Execution, as: ExecFixtures

  test "reserves helper-task slots without creating waiters" do
    limiter = start_limiter(2)

    assert ConcurrencyLimiter.reserve_task_slots(limiter, 4) == 2
    assert ConcurrencyLimiter.reserve_task_slots(limiter, 1) == 0

    assert :ok = ConcurrencyLimiter.release_task_slots(limiter, 1)
    assert ConcurrencyLimiter.reserve_task_slots(limiter, 2) == 1

    assert :ok = ConcurrencyLimiter.release_task_slots(limiter, 2)
    assert ConcurrencyLimiter.reserve_task_slots(limiter, 1) == 1
  end

  test "runs nested work inline when no helper-task slot is available" do
    limiter = start_limiter(1)
    assert ConcurrencyLimiter.reserve_task_slots(limiter, 1) == 1

    caller = self()

    assert [{^caller, :first}, {^caller, :second}] =
             OrderedTaskRunner.run(
               [:first, :second],
               2,
               &{self(), &1},
               fn item, reason -> {item, reason} end,
               limiter
             )
  end

  test "creates one scoped limiter and supports permit-free calls" do
    assert ConcurrencyLimiter.with_permit(nil, fn -> :inline end) == :inline
    assert ConcurrencyLimiter.reserve_task_slots(nil, 3) == 3
    assert ConcurrencyLimiter.release_task_slots(nil, 3) == :ok
    assert ConcurrencyLimiter.stop(nil) == :ok

    execution_id = "scoped-limiter-#{System.unique_integer([:positive])}"

    assert ConcurrencyLimiter.with_limiter(execution_id, 2, false, fn ->
             assert ConcurrencyLimiter.whereis(execution_id) == nil
             :serial
           end) == :serial

    assert ConcurrencyLimiter.with_limiter(execution_id, 2, true, fn ->
             limiter = ConcurrencyLimiter.whereis(execution_id)
             assert is_pid(limiter)

             ConcurrencyLimiter.with_limiter(execution_id, 2, true, fn ->
               assert ConcurrencyLimiter.whereis(execution_id) == limiter
               :nested
             end)
           end) == :nested

    assert ConcurrencyLimiter.whereis(execution_id) == nil
  end

  test "grants permits after a holder exits and removes a dead waiter" do
    limiter = start_limiter(1)
    test_pid = self()

    holder =
      spawn(fn ->
        ConcurrencyLimiter.with_permit(limiter, fn ->
          send(test_pid, {:holder_ready, self()})
          receive do: (:finish -> :ok)
        end)
      end)

    assert_receive {:holder_ready, ^holder}, 1_000

    {dead_waiter, dead_waiter_monitor} =
      spawn_monitor(fn ->
        request = make_ref()
        send(limiter, {:"$gen_call", {self(), request}, :acquire})
        send(test_pid, {:waiter_request_sent, self()})
        receive do: ({^request, reply} -> reply)
      end)

    assert_receive {:waiter_request_sent, ^dead_waiter}, 1_000
    Process.exit(dead_waiter, :kill)
    assert_receive {:DOWN, ^dead_waiter_monitor, :process, ^dead_waiter, :killed}, 1_000

    {next, next_monitor} =
      spawn_monitor(fn ->
        ConcurrencyLimiter.with_permit(limiter, fn -> send(test_pid, :next_granted) end)
      end)

    send(holder, :finish)
    assert_receive :next_granted, 1_000
    assert_receive {:DOWN, ^next_monitor, :process, ^next, :normal}, 1_000
  end

  test "releases reserved task slots when their holder exits" do
    limiter = start_limiter(2)
    test_pid = self()

    holder =
      spawn(fn ->
        assert ConcurrencyLimiter.reserve_task_slots(limiter, 2) == 2
        send(test_pid, {:slots_reserved, self()})
        receive do: (:finish -> :ok)
      end)

    assert_receive {:slots_reserved, ^holder}, 1_000
    assert ConcurrencyLimiter.reserve_task_slots(limiter, 1) == 0
    holder_monitor = Process.monitor(holder)
    Process.exit(holder, :kill)
    assert_receive {:DOWN, ^holder_monitor, :process, ^holder, :killed}, 1_000

    assert ConcurrencyLimiter.reserve_task_slots(limiter, 1) == 1
    assert ConcurrencyLimiter.release_task_slots(limiter, 1) == :ok
  end

  test "normalizes inline and asynchronous worker exits in source order" do
    worker = fn
      :raise -> raise "raised"
      :throw -> throw(:thrown)
      :exit -> exit(:exited)
      value -> value
    end

    exit_fun = fn item, _reason -> {:failed, item} end

    assert OrderedTaskRunner.run([:raise, :throw, :exit, :ok], 1, worker, exit_fun) == [
             {:failed, :raise},
             {:failed, :throw},
             {:failed, :exit},
             :ok
           ]

    assert OrderedTaskRunner.run([:ok, :raise, :throw, :exit], 4, worker, exit_fun) == [
             :ok,
             {:failed, :raise},
             {:failed, :throw},
             {:failed, :exit}
           ]
  end

  test "contains stale limiter calls and unmatched releases" do
    {dead_limiter, monitor} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^monitor, :process, ^dead_limiter, :normal}, 1_000

    assert ConcurrencyLimiter.reserve_task_slots(dead_limiter, 1) == 0
    assert ConcurrencyLimiter.release_task_slots(dead_limiter, 1) == :ok

    limiter = start_limiter(1)
    assert GenServer.call(limiter, {:release, self()}) == :ok
    assert ConcurrencyLimiter.release_task_slots(limiter, 1) == :ok
    assert ConcurrencyLimiter.stop(limiter) == :ok
    assert ConcurrencyLimiter.stop(limiter) == :ok
  end

  test "a Flow timeout stops and unregisters its execution limiter" do
    handler_id = "limiter-timeout-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:jido, :flow, :start],
        &__MODULE__.handle_flow_start/4,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    flow =
      Flow.new!(
        name: "limiter_timeout",
        components: [
          Step.new!(name: "left", action: ExecFixtures.BlockingAction, params: %{side: :left}),
          Step.new!(name: "right", action: ExecFixtures.BlockingAction, params: %{side: :right})
        ],
        output: %{left: Ref.result("left"), right: Ref.result("right")}
      )

    task =
      Task.async(fn ->
        Exec.run(flow, %{}, %{test_pid: test_pid},
          async: true,
          max_concurrency: 2,
          timeout: 1_000
        )
      end)

    assert_receive {:flow_started, execution_id}, 1_000
    assert_receive {:blocking_flow_node_started, first_worker}, 1_000
    assert_receive {:blocking_flow_node_started, second_worker}, 1_000

    limiter = ConcurrencyLimiter.whereis(execution_id)
    assert is_pid(limiter)
    limiter_monitor = Process.monitor(limiter)
    first_monitor = Process.monitor(first_worker)
    second_monitor = Process.monitor(second_worker)

    assert {:error, %Jido.Flow.Error.TimeoutError{}} = Task.await(task, 2_000)
    assert_receive {:DOWN, ^limiter_monitor, :process, ^limiter, _reason}, 1_000
    assert_receive {:DOWN, ^first_monitor, :process, ^first_worker, _reason}, 1_000
    assert_receive {:DOWN, ^second_monitor, :process, ^second_worker, _reason}, 1_000
    assert ConcurrencyLimiter.whereis(execution_id) == nil
  end

  @doc false
  def handle_flow_start(_event, _measurements, metadata, owner) do
    send(owner, {:flow_started, metadata.execution_id})
  end

  defp start_limiter(limit) do
    execution_id = "limiter-test-#{System.unique_integer([:positive])}"
    assert {:ok, limiter} = ConcurrencyLimiter.start(execution_id, self(), limit)
    limiter
  end
end
