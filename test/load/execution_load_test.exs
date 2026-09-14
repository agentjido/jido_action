defmodule JidoActionTest.Load.ExecutionLoadTest do
  use ExUnit.Case, async: false
  @moduletag :load
  @moduletag timeout: 60_000

  alias Jido.Exec
  alias JidoActionTest.Fixtures.Execution.SystemLoad
  alias JidoActionTest.Fixtures.Execution.SystemLoad.CountedWork

  setup do
    ledger = start_supervised!({Agent, &SystemLoad.initial_ledger/0})
    supervisor = start_supervised!({Task.Supervisor, []})
    {:ok, ledger: ledger, supervisor: supervisor, seed: seed!()}
  end

  test "wide Flow and Map keep exact work and input order within the limit", context do
    for {kind, items} <- [
          {:wide, Enum.to_list(1..24)},
          {:map, ordered_items(context.seed, 40)}
        ] do
      Agent.update(context.ledger, fn _ -> SystemLoad.initial_ledger() end)
      ref = make_ref()

      flow =
        if kind == :wide, do: SystemLoad.wide_flow(length(items)), else: SystemLoad.map_flow()

      input = if kind == :wide, do: %{}, else: %{items: items}

      handle =
        Exec.run_async(
          flow,
          input,
          %{observer: self(), run_ref: ref, ledger: context.ledger},
          max_concurrency: 4,
          task_supervisor: context.supervisor
        )

      ready =
        for _ <- 1..div(length(items), 4), reduce: [] do
          seen ->
            batch =
              for _ <- 1..4 do
                assert_receive {^ref, :ready, id, pid},
                               10_000,
                               "seed=#{context.seed} kind=#{kind}"

                {id, pid}
              end

            Enum.each(batch, fn {_id, pid} -> send(pid, {ref, :release}) end)
            batch ++ seen
        end

      expected =
        if kind == :wide,
          do: %{values: items},
          else: %{mapped: Enum.map(items, &%{id: &1, value: &1})}

      assert Exec.await(handle, 10_000) == {:ok, expected}, "seed=#{context.seed} kind=#{kind}"

      ledger = SystemLoad.snapshot(context.ledger)
      assert Enum.sort(Enum.map(ready, &elem(&1, 0))) == Enum.sort(items)
      assert Enum.sort(ledger.started) == Enum.sort(items)
      assert Enum.sort(ledger.completed) == Enum.sort(items)
      assert ledger.active == 0
      assert ledger.peak <= 4
      assert Task.Supervisor.children(context.supervisor) == []
      refute_received {^ref, :ready, _, _}
    end
  end

  test "seeded mixed sync and async calls run each Action once", context do
    expected_calls =
      for index <- 1..60, reduce: [] do
        calls ->
          ref = make_ref()
          value = rem(context.seed + index * 37, 997)
          mode = rem(context.seed + index, 3)
          run_context = %{ledger: context.ledger, run_ref: ref, observer: self()}
          options = [task_supervisor: context.supervisor, max_concurrency: rem(index, 4) + 1]

          {result, ids, handle_pid} =
            case mode do
              0 ->
                {Exec.run(CountedWork, %{id: :direct, value: value}, run_context, options),
                 [:direct], nil}

              1 ->
                {Exec.run(SystemLoad.counted_flow(), %{value: value}, run_context, options),
                 [:first, :second], nil}

              2 ->
                handle =
                  Exec.run_async(SystemLoad.counted_flow(), %{value: value}, run_context, options)

                {Exec.await(handle, 10_000), [:first, :second], handle.pid}
            end

          expected = if mode == 0, do: %{id: :direct, value: value}, else: %{value: value}
          assert result == {:ok, expected}, "seed=#{context.seed} call=#{index} mode=#{mode}"

          for id <- ids do
            assert_receive {^ref, :worker_done, ^id, pid}, 5_000
            monitor = Process.monitor(pid)
            assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 5_000
          end

          if handle_pid do
            monitor = Process.monitor(handle_pid)
            assert_receive {:DOWN, ^monitor, :process, ^handle_pid, _}, 5_000
          end

          assert Task.Supervisor.children(context.supervisor) == []
          Enum.map(ids, &{ref, &1}) ++ calls
      end

    ledger = SystemLoad.snapshot(context.ledger)
    assert Enum.sort(ledger.started) == Enum.sort(expected_calls)
    assert Enum.sort(ledger.completed) == Enum.sort(expected_calls)
    assert length(ledger.started) == length(Enum.uniq(ledger.started))
    assert ledger.active == 0
  end

  defp seed! do
    value = System.get_env("JIDO_ACTION_LOAD_SEED", "20260914")

    case Integer.parse(value) do
      {seed, ""} when seed > 0 -> seed
      _ -> raise ArgumentError, "JIDO_ACTION_LOAD_SEED must be a positive integer"
    end
  end

  defp ordered_items(seed, count) do
    Enum.sort_by(1..count, fn item -> rem(item * 37 + seed, count + 1) end)
  end
end
