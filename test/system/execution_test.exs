defmodule JidoActionTest.System.ExecutionTest do
  use ExUnit.Case, async: false
  @moduletag :system
  @moduletag timeout: 15_000

  alias Jido.Exec
  alias JidoActionTest.Fixtures.Execution.SystemLoad

  @telemetry_events for kind <- [:flow, :node, :target],
                        terminal <- [:start, :stop, :error],
                        do: [:jido, :flow, kind, terminal]
  @telemetry_events Enum.map(@telemetry_events, fn
                      [:jido, :flow, :flow, terminal] -> [:jido, :flow, terminal]
                      event -> event
                    end)
  @telemetry_events @telemetry_events ++
                      for(
                        terminal <- [:start, :stop, :error],
                        do: [:jido, :flow, :map, :item, terminal]
                      )

  setup do
    ledger = start_supervised!({Agent, &SystemLoad.initial_ledger/0})
    supervisor = start_supervised!({Task.Supervisor, []})
    event_ref = make_ref()
    observer = self()
    handler = {__MODULE__, event_ref}

    :ok =
      :telemetry.attach_many(
        handler,
        @telemetry_events,
        &__MODULE__.telemetry_handler/4,
        {observer, event_ref}
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    {:ok, ledger: ledger, supervisor: supervisor, event_ref: event_ref}
  end

  test "composed Steps and Map finish once, keep order, and close telemetry", context do
    ref = make_ref()
    flow = SystemLoad.composed_flow()

    handle =
      Exec.run_async(
        flow,
        %{left: 10, right: 20, items: [3, 1, 2]},
        runtime_context(context, ref),
        max_concurrency: 2,
        task_supervisor: context.supervisor
      )

    first = take_ready(ref, 2)
    assert first |> Enum.map(&elem(&1, 0)) |> Enum.sort() == [:left, :right]
    release(ref, first)

    mapped = take_ready(ref, 2)
    release(ref, mapped)
    last = take_ready(ref, 1)
    release(ref, last)

    assert Enum.sort(Enum.map(mapped ++ last, &elem(&1, 0))) == [1, 2, 3]
    assert {:ok, %{left: 10, right: 20, mapped: mapped_result}} = Exec.await(handle, 5_000)
    assert mapped_result == for(id <- [3, 1, 2], do: %{id: id, value: id})

    ledger = SystemLoad.snapshot(context.ledger)
    assert ledger.active == 0
    assert ledger.peak <= 2
    assert Enum.sort(ledger.started) == Enum.sort([1, 2, 3, :left, :right])
    assert Enum.sort(ledger.completed) == Enum.sort(ledger.started)
    assert Task.Supervisor.children(context.supervisor) == []
    refute_received {^ref, :ready, _, _}

    assert_lifecycles(context.event_ref, %{flow: 1, node: 3, target: 2, map_item: 3}, :stop)
  end

  test "injected failure stops the composed graph before Map admission", context do
    ref = make_ref()

    handle =
      Exec.run_async(
        SystemLoad.composed_flow(),
        %{left: 10, right: 20, items: [3, 1, 2]},
        runtime_context(context, ref),
        max_concurrency: 2,
        task_supervisor: context.supervisor
      )

    workers = take_ready(ref, 2)
    {_, failed} = Enum.find(workers, fn {id, _pid} -> id == :right end)
    {_, held} = Enum.find(workers, fn {id, _pid} -> id == :left end)
    send(failed, {ref, :fail})
    send(held, {ref, :release})

    assert {:error, %{message: "injected held-work failure"}} = Exec.await(handle, 5_000)
    assert Enum.sort(SystemLoad.snapshot(context.ledger).started) == [:left, :right]
    assert Task.Supervisor.children(context.supervisor) == []
    refute_received {^ref, :ready, _, _}

    assert_lifecycles(context.event_ref, %{flow: 1, node: 2, target: 2, map_item: 0}, :error)
  end

  for terminal <- [:cancel, :timeout] do
    @tag terminal: terminal
    test "#{terminal} stops all held workers and closes active spans", context do
      ref = make_ref()
      opts = [max_concurrency: 2, task_supervisor: context.supervisor]
      opts = if context.terminal == :timeout, do: Keyword.put(opts, :timeout, 2_000), else: opts

      handle =
        Exec.run_async(
          SystemLoad.composed_flow(),
          %{left: 10, right: 20, items: [3, 1, 2]},
          runtime_context(context, ref),
          opts
        )

      workers = take_ready(ref, 2)
      monitors = for {_id, pid} <- workers, do: {pid, Process.monitor(pid)}

      if context.terminal == :cancel do
        assert :ok = Exec.cancel(handle)
      else
        assert {:error, %Jido.Flow.Error.TimeoutError{timeout: 2_000}} = Exec.await(handle, 5_000)
      end

      for {pid, monitor} <- monitors do
        assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 5_000
      end

      assert Task.Supervisor.children(context.supervisor) == []
      refute_received {^ref, :ready, _, _}
      assert_lifecycles(context.event_ref, %{flow: 1, node: 2, target: 2, map_item: 0}, :error)
    end
  end

  test "owner death stops the async handle and its held workers", context do
    ref = make_ref()
    observer = self()

    owner =
      spawn(fn ->
        handle =
          Exec.run_async(
            SystemLoad.composed_flow(),
            %{left: 10, right: 20, items: [3, 1, 2]},
            runtime_context(context, ref, observer),
            max_concurrency: 2,
            task_supervisor: context.supervisor
          )

        send(observer, {ref, :handle, handle})
        receive do: (:stop -> :ok)
      end)

    on_exit(fn ->
      if Process.alive?(owner), do: Process.exit(owner, :kill)
    end)

    assert_receive {^ref, :handle, handle}, 5_000
    workers = take_ready(ref, 2)
    handle_monitor = Process.monitor(handle.pid)
    monitors = for {_id, pid} <- workers, do: {pid, Process.monitor(pid)}
    send(owner, :stop)

    assert_receive {:DOWN, ^handle_monitor, :process, _, _}, 5_000

    for {pid, monitor} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 5_000
    end

    assert Task.Supervisor.children(context.supervisor) == []
    refute_received {^ref, :ready, _, _}
    assert_lifecycles(context.event_ref, %{flow: 1, node: 2, target: 2, map_item: 0}, :error)
  end

  test "supervisor shutdown ends held work and returns a structured error", context do
    ref = make_ref()
    observer = self()

    caller =
      Task.async(fn ->
        result =
          Exec.run(
            SystemLoad.composed_flow(),
            %{left: 10, right: 20, items: [3, 1, 2]},
            runtime_context(context, ref, observer),
            max_concurrency: 2,
            task_supervisor: context.supervisor
          )

        send(observer, {ref, :result, result})
        :ok
      end)

    workers = take_ready(ref, 2)
    monitors = for {_id, pid} <- workers, do: {pid, Process.monitor(pid)}
    assert :ok = Supervisor.stop(context.supervisor)

    for {pid, monitor} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 5_000
    end

    assert_receive {^ref, :result,
                    {:error, %Jido.Flow.Error.ExecutionFailureError{failures: failures}}},
                   5_000

    assert length(failures) == 2
    assert Enum.sort(Enum.map(failures, & &1.error.details.node_path)) == [["left"], ["right"]]
    assert Enum.all?(failures, &(&1.error.details.reason == :shutdown))
    assert :ok = Task.await(caller, 5_000)
    refute_received {^ref, :ready, _, _}
    assert_lifecycles(context.event_ref, %{flow: 1, node: 2, target: 2, map_item: 0}, :error)
  end

  defp runtime_context(context, ref, observer \\ self()) do
    %{observer: observer, run_ref: ref, ledger: context.ledger}
  end

  @doc false
  def telemetry_handler(event, measurements, metadata, {observer, ref}) do
    send(observer, {ref, :telemetry, event, measurements, metadata})
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

  defp assert_lifecycles(ref, expected_counts, terminal) do
    events = telemetry(ref)
    ids = Enum.map(events, fn {_event, _measurements, metadata} -> metadata.execution_id end)
    assert length(Enum.uniq(ids)) == 1

    for {kind, count} <- expected_counts do
      prefix =
        case kind do
          :flow -> [:jido, :flow]
          :map_item -> [:jido, :flow, :map, :item]
          _ -> [:jido, :flow, kind]
        end

      starts = Enum.filter(events, fn {event, _, _} -> event == prefix ++ [:start] end)

      terminals =
        Enum.filter(events, fn {event, _, _} ->
          event in [prefix ++ [:stop], prefix ++ [:error]]
        end)

      assert length(starts) == count
      assert length(terminals) == count

      signature = fn {_event, _measurements, metadata} ->
        Map.take(metadata, [:execution_id, :flow, :node, :target, :kind, :option])
      end

      assert Enum.sort(Enum.map(starts, signature)) ==
               Enum.sort(Enum.map(terminals, signature))

      if kind == :flow do
        assert Enum.map(terminals, &elem(&1, 0)) == [prefix ++ [terminal]]
      end

      for {_, measurements, _} <- terminals, do: assert(is_integer(measurements.duration))
    end
  end

  defp telemetry(ref, events \\ []) do
    receive do
      {^ref, :telemetry, event, measurements, metadata} ->
        telemetry(ref, [{event, measurements, metadata} | events])
    after
      0 -> Enum.reverse(events)
    end
  end
end
