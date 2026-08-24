defmodule Jido.Exec.ConcurrencyLimiterTest do
  use ExUnit.Case, async: true

  alias Jido.Exec.ConcurrencyLimiter
  alias Jido.Flow.Runtime.OrderedTaskRunner

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

  defp start_limiter(limit) do
    execution_id = "limiter-test-#{System.unique_integer([:positive])}"
    assert {:ok, limiter} = ConcurrencyLimiter.start(execution_id, self(), limit)
    limiter
  end
end
