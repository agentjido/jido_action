defmodule JidoActionTest.Load.ScenariosTest do
  use ExUnit.Case, async: false
  @moduletag :load
  @moduletag timeout: 120_000

  alias Jido.Exec
  alias JidoActionTest.Fixtures.Execution.SystemLoad
  alias JidoActionTest.Fixtures.Execution.SystemLoad.CountedWork

  @modes [:sync_action, :sync_flow, :async_flow, :stepwise, :timeout, :cancel, :fault]

  setup do
    ledger = start_supervised!({Agent, &SystemLoad.initial_ledger/0})
    supervisor = start_supervised!({Task.Supervisor, []})
    {:ok, ledger: ledger, supervisor: supervisor}
  end

  test "a seeded sequence mixes every execution mode and reports its first failing case",
       context do
    seed = seed!()

    for index <- selected_cases() do
      mode = Enum.at(@modes, rem(seed + index, length(@modes)))
      input_size = if mode == :stepwise, do: 4 + rem(index, 5), else: 1
      descriptor = "seed=#{seed} case=#{index} input_size=#{input_size} mode=#{mode}"

      try do
        run_case(index, input_size, mode, seed, context)
      rescue
        error ->
          IO.warn(
            "first failing load case: #{descriptor}; replay with JIDO_ACTION_LOAD_SEED=#{seed} JIDO_ACTION_LOAD_CASE=#{index} mix test test/load/scenarios_test.exs --only load"
          )

          reraise error, __STACKTRACE__
      end
    end
  end

  test "six callers keep separate results and execution IDs on one supervisor", context do
    observer = self()
    flow = SystemLoad.composed_flow()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:jido, :flow, :start],
        &__MODULE__.telemetry_handler/4,
        observer
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    callers =
      for index <- 1..6 do
        ref = make_ref()
        items = for offset <- [3, 1, 2], do: index * 10 + offset
        input = %{left: index, right: index * 10, items: items}

        task =
          Task.async(fn ->
            handle =
              Exec.run_async(
                flow,
                input,
                %{observer: observer, run_ref: ref, ledger: context.ledger},
                max_concurrency: 2,
                task_supervisor: context.supervisor
              )

            send(observer, {ref, :handle, handle})
            Exec.await(handle, 10_000)
          end)

        %{index: index, ref: ref, items: items, task: task}
      end

    callers =
      for caller <- callers do
        ref = caller.ref
        assert_receive {^ref, :handle, handle}, 5_000
        assert handle.owner == caller.task.pid
        Map.merge(caller, %{handle: handle, monitor: Process.monitor(handle.pid)})
      end

    for caller <- callers do
      workers = take_ready(caller.ref, 2)
      assert Enum.sort(Enum.map(workers, &elem(&1, 0))) == [:left, :right]
      release(caller.ref, workers)
    end

    for caller <- callers do
      first = take_ready(caller.ref, 2)
      release(caller.ref, first)
      last = take_ready(caller.ref, 1)
      release(caller.ref, last)
      assert Enum.sort(Enum.map(first ++ last, &elem(&1, 0))) == Enum.sort(caller.items)
    end

    for caller <- callers do
      assert {:ok, result} = Task.await(caller.task, 10_000)

      assert result == %{
               left: caller.index,
               right: caller.index * 10,
               mapped: Enum.map(caller.items, &%{id: &1, value: &1})
             }

      monitor = caller.monitor
      pid = caller.handle.pid
      ref = caller.ref
      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 5_000
      refute_received {^ref, :ready, _, _}
    end

    ids =
      for _ <- callers do
        assert_receive {:load_flow_start, execution_id}, 5_000
        execution_id
      end

    assert length(Enum.uniq(ids)) == length(callers)
    ledger = SystemLoad.snapshot(context.ledger)
    assert length(ledger.started) == 6 * 5
    assert Enum.frequencies(ledger.completed) == Enum.frequencies(ledger.started)
    assert ledger.active == 0
    assert_supervisor_quiescent(context.supervisor)
  end

  test "quiescent resource counts return to a bounded baseline after each outcome", context do
    baseline = resource_snapshot(context.supervisor)
    assert baseline.children == 0

    for outcome <- [:success, :timeout, :cancel, :fault] do
      ref = make_ref()

      handle =
        Exec.run_async(
          SystemLoad.wide_flow(1),
          %{},
          %{observer: self(), run_ref: ref, ledger: context.ledger},
          max_concurrency: 1,
          task_supervisor: context.supervisor
        )

      [{1, worker}] = take_ready(ref, 1)
      worker_monitor = Process.monitor(worker)
      handle_monitor = Process.monitor(handle.pid)

      case outcome do
        :success ->
          send(worker, {ref, :release})
          assert {:ok, %{values: [1]}} = Exec.await(handle, 5_000)

        :timeout ->
          assert {:error, %Jido.Exec.Error.AsyncTimeoutError{}} = Exec.await(handle, 0)

        :cancel ->
          assert :ok = Exec.cancel(handle)

        :fault ->
          send(worker, {ref, :fail})
          assert {:error, %Jido.Action.Error.ExecutionFailureError{}} = Exec.await(handle, 5_000)
      end

      assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _}, 5_000
      assert_receive {:DOWN, ^handle_monitor, :process, _, _}, 5_000
      assert_supervisor_quiescent(context.supervisor)
      snapshot = resource_snapshot(context.supervisor, [worker, handle.pid])
      assert snapshot.owned_processes == baseline.owned_processes
      assert snapshot.children == baseline.children
      assert snapshot.handlers == baseline.handlers
      assert snapshot.mailbox <= baseline.mailbox + 2
      assert snapshot.processes <= baseline.processes + 8
    end
  end

  defp run_case(index, input_size, mode, seed, context) do
    Agent.update(context.ledger, fn _ -> SystemLoad.initial_ledger() end)
    ref = make_ref()
    value = rem(seed + index * 37, 997)
    run_context = %{ledger: context.ledger, run_ref: ref, observer: self()}
    options = [task_supervisor: context.supervisor, max_concurrency: rem(index, 4) + 1]

    expected_ids =
      case mode do
        :sync_action ->
          assert {:ok, %{id: ^index, value: ^value}} =
                   Exec.run(CountedWork, %{id: index, value: value}, run_context, options)

          [{ref, index}]

        :sync_flow ->
          assert {:ok, %{value: ^value}} =
                   Exec.run(SystemLoad.counted_flow(), %{value: value}, run_context, options)

          [{ref, :first}, {ref, :second}]

        :async_flow ->
          handle =
            Exec.run_async(SystemLoad.counted_flow(), %{value: value}, run_context, options)

          monitor = Process.monitor(handle.pid)
          assert {:ok, %{value: ^value}} = Exec.await(handle, 5_000)
          assert_receive {:DOWN, ^monitor, :process, _, :normal}, 5_000
          [{ref, :first}, {ref, :second}]

        :stepwise ->
          assert {:ok, execution} =
                   Exec.start(
                     SystemLoad.deep_flow(input_size),
                     %{value: value},
                     run_context,
                     options
                   )

          assert {:ok, %{value: ^value}} = run_stepwise(execution)
          for id <- 1..input_size, do: {ref, id}

        :timeout ->
          held_case(:timeout, ref, run_context, options)
          [1]

        :cancel ->
          held_case(:cancel, ref, run_context, options)
          [1]

        :fault ->
          held_case(:fault, ref, run_context, options)
          [1]
      end

    if mode in [:sync_action, :sync_flow, :async_flow, :stepwise] do
      for _id <- expected_ids do
        assert_receive {^ref, :worker_done, worker_id, _pid}, 5_000
        assert {ref, worker_id} in expected_ids
      end
    end

    ledger = SystemLoad.snapshot(context.ledger)
    assert Enum.frequencies(ledger.started) == Enum.frequencies(expected_ids)

    if mode in [:timeout, :cancel, :fault] do
      assert ledger.completed == []
    else
      assert Enum.frequencies(ledger.completed) == Enum.frequencies(expected_ids)
    end

    assert_supervisor_quiescent(context.supervisor)
  end

  defp held_case(mode, ref, run_context, options) do
    options = if mode == :timeout, do: Keyword.put(options, :timeout, 1_000), else: options
    handle = Exec.run_async(SystemLoad.wide_flow(1), %{}, run_context, options)
    [{1, worker}] = take_ready(ref, 1)
    worker_monitor = Process.monitor(worker)
    handle_monitor = Process.monitor(handle.pid)

    case mode do
      :timeout ->
        assert {:error, %Jido.Flow.Error.TimeoutError{timeout: 1_000}} =
                 Exec.await(handle, 5_000)

      :cancel ->
        assert :ok = Exec.cancel(handle)

      :fault ->
        send(worker, {ref, :fail})
        assert {:error, %Jido.Action.Error.ExecutionFailureError{}} = Exec.await(handle, 5_000)
    end

    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _}, 5_000
    assert_receive {:DOWN, ^handle_monitor, :process, _, _}, 5_000
  end

  defp run_stepwise(execution) do
    if Exec.status(execution) == :running do
      assert [_ | _] = Exec.ready(execution)
      assert {:ok, _work, next} = Exec.step(execution)
      run_stepwise(next)
    else
      Exec.result(execution)
    end
  end

  defp take_ready(ref, count) do
    for _ <- 1..count do
      assert_receive {^ref, :ready, id, pid}, 5_000
      {id, pid}
    end
  end

  defp release(ref, workers) do
    Enum.each(workers, fn {_id, pid} -> send(pid, {ref, :release}) end)
  end

  defp seed! do
    value = System.get_env("JIDO_ACTION_LOAD_SEED", "20260914")

    case Integer.parse(value) do
      {seed, ""} when seed > 0 -> seed
      _ -> raise ArgumentError, "JIDO_ACTION_LOAD_SEED must be a positive integer"
    end
  end

  defp selected_cases do
    case System.get_env("JIDO_ACTION_LOAD_CASE") do
      nil ->
        1..28

      value ->
        case Integer.parse(value) do
          {index, ""} when index in 1..28 -> [index]
          _ -> raise ArgumentError, "JIDO_ACTION_LOAD_CASE must be an integer from 1 to 28"
        end
    end
  end

  defp resource_snapshot(supervisor, owned_pids \\ []) do
    %{
      owned_processes: Enum.count(owned_pids, &Process.alive?/1),
      processes: :erlang.system_info(:process_count),
      children: length(Task.Supervisor.children(supervisor)),
      mailbox: elem(Process.info(self(), :message_queue_len), 1),
      handlers: length(:telemetry.list_handlers([:jido, :flow, :start]))
    }
  end

  defp assert_supervisor_quiescent(supervisor) do
    for pid <- Task.Supervisor.children(supervisor) do
      monitor = Process.monitor(pid)
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 5_000
    end

    assert Task.Supervisor.children(supervisor) == []
  end

  @doc false
  def telemetry_handler(_event, _measurements, metadata, observer) do
    send(observer, {:load_flow_start, metadata.execution_id})
  end
end
