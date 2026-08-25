defmodule JidoActionTest.Exec.ConcurrencyLimiterTest do
  use ExUnit.Case, async: true

  alias Jido.Exec.ConcurrencyLimiter
  alias Jido.Exec.OrderedTaskRunner

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

    dead_waiter = spawn(fn -> ConcurrencyLimiter.with_permit(limiter, fn -> :ok end) end)
    Process.sleep(5)
    Process.exit(dead_waiter, :kill)

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
    Process.exit(holder, :kill)

    assert eventually(fn -> ConcurrencyLimiter.reserve_task_slots(limiter, 1) == 1 end)
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

  defp start_limiter(limit) do
    execution_id = "limiter-test-#{System.unique_integer([:positive])}"
    assert {:ok, limiter} = ConcurrencyLimiter.start(execution_id, self(), limit)
    limiter
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(1)
      eventually(fun, attempts - 1)
    end
  end
end
