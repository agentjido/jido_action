defmodule JidoActionTest.Load.ExecutionLoadTest do
  use ExUnit.Case, async: false
  import JidoActionTest.ProcessCleanup
  @moduletag :load
  @moduletag timeout: 120_000

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
      assert_supervisor_quiescent(context.supervisor)
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

          assert_supervisor_quiescent(context.supervisor)
          Enum.map(ids, &{ref, &1}) ++ calls
      end

    ledger = SystemLoad.snapshot(context.ledger)
    assert Enum.sort(ledger.started) == Enum.sort(expected_calls)
    assert Enum.sort(ledger.completed) == Enum.sort(expected_calls)
    assert length(ledger.started) == length(Enum.uniq(ledger.started))
    assert ledger.active == 0
  end

  test "deep and shared-prerequisite graphs run each producer once", context do
    deep_count = 128
    deep_ref = make_ref()
    deep_context = %{ledger: context.ledger, run_ref: deep_ref, observer: self()}

    assert Exec.run(SystemLoad.deep_flow(deep_count), %{value: 17}, deep_context,
             task_supervisor: context.supervisor,
             max_concurrency: 4
           ) == {:ok, %{value: 17}}

    assert_exact_workers(deep_ref, Enum.to_list(1..deep_count), context)

    Agent.update(context.ledger, fn _ -> SystemLoad.initial_ledger() end)
    width = 16
    diamond_ref = make_ref()
    diamond_context = %{ledger: context.ledger, run_ref: diamond_ref, observer: self()}
    producers = for index <- 1..width, do: "producer_#{index}"
    readers = for index <- 1..width, do: "reader_#{index}"
    shared_values = Map.new(producers, &{&1, 17})

    assert Exec.run(SystemLoad.diamond_flow(width), %{value: 17}, diamond_context,
             task_supervisor: context.supervisor,
             max_concurrency: 4
           ) == {:ok, %{readers: List.duplicate(shared_values, width)}}

    assert_exact_workers(diamond_ref, ["root" | producers ++ readers], context)
  end

  test "Map keeps identity, order, and a four-worker bound through 1,000 items", context do
    flow = SystemLoad.map_flow_with_ids()

    first_ids =
      for count <- [40, 200, 1_000] do
        items = ordered_items(context.seed, count)
        mapped = run_gated_map(flow, items, context)
        assert Enum.map(mapped, &{&1.id, &1.value}) == Enum.map(items, &{&1, &1})
        ids = Enum.map(mapped, & &1.item_id)
        assert length(Enum.uniq(ids)) == count
        {count, ids}
      end
      |> Map.new()

    replay_items = ordered_items(context.seed, 40)
    replay_ids = run_gated_map(flow, replay_items, context) |> Enum.map(& &1.item_id)
    assert replay_ids == first_ids[40]

    duplicates = Enum.map(1..40, &rem(&1, 5))
    duplicate_output = run_gated_map(flow, duplicates, context)
    assert Enum.map(duplicate_output, & &1.value) == duplicates
    assert length(Enum.uniq(Enum.map(duplicate_output, & &1.item_id))) == 40
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

  defp assert_exact_workers(ref, expected_ids, context) do
    workers =
      for _ <- expected_ids do
        assert_receive {^ref, :worker_done, id, pid},
                       10_000,
                       "seed=#{context.seed} expected=#{length(expected_ids)}"

        {id, pid}
      end

    assert Enum.sort(Enum.map(workers, &elem(&1, 0))) == Enum.sort(expected_ids)

    for {_id, pid} <- workers do
      monitor = Process.monitor(pid)
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 10_000
    end

    ledger = SystemLoad.snapshot(context.ledger)
    assert ledger.active == 0

    assert Enum.frequencies(ledger.started) ==
             Enum.frequencies(for(id <- expected_ids, do: {ref, id}))

    assert Enum.frequencies(ledger.completed) == Enum.frequencies(ledger.started)
    assert_supervisor_quiescent(context.supervisor)
    refute_received {^ref, :worker_done, _, _}
  end

  defp run_gated_map(flow, items, context) do
    Agent.update(context.ledger, fn _ -> SystemLoad.initial_ledger() end)
    ref = make_ref()

    handle =
      Exec.run_async(
        flow,
        %{items: items},
        %{ledger: context.ledger, run_ref: ref, observer: self()},
        max_concurrency: 4,
        task_supervisor: context.supervisor
      )

    handle_monitor = Process.monitor(handle.pid)

    monitors =
      for _batch <- Enum.chunk_every(items, 4), reduce: [] do
        seen ->
          workers =
            for _ <- 1..4 do
              assert_receive {^ref, :ready, id, pid},
                             10_000,
                             "seed=#{context.seed} map_items=#{length(items)}"

              {id, pid}
            end

          monitors = for {_id, pid} <- workers, do: {pid, Process.monitor(pid)}
          Enum.each(workers, fn {_id, pid} -> send(pid, {ref, :release}) end)
          monitors ++ seen
      end

    result = Exec.await(handle, 60_000)
    ledger_after = SystemLoad.snapshot(context.ledger)

    mapped =
      case result do
        {:ok, %{mapped: mapped}} ->
          mapped

        other ->
          flunk(
            "items=#{length(items)} started=#{length(ledger_after.started)} completed=#{length(ledger_after.completed)} active=#{ledger_after.active} peak=#{ledger_after.peak} result=#{inspect(other)}"
          )
      end

    for {pid, monitor} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 10_000
    end

    assert_receive {:DOWN, ^handle_monitor, :process, _, :normal}, 10_000
    ledger = SystemLoad.snapshot(context.ledger)
    assert Enum.sort(ledger.started) == Enum.sort(items)
    assert Enum.sort(ledger.completed) == Enum.sort(items)
    assert ledger.active == 0
    assert ledger.peak <= 4
    assert_supervisor_quiescent(context.supervisor)
    refute_received {^ref, :ready, _, _}
    mapped
  end
end
