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
  @telemetry_events @telemetry_events ++
                      for(
                        kind <- [[:reduce, :item], [:iterate, :iteration]],
                        terminal <- [:start, :stop, :error],
                        do: [:jido, :flow] ++ kind ++ [terminal]
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

  test "all Flow components compose with exact leaf work and input-order results", context do
    assert SystemLoad.CombinedChild.flow() == SystemLoad.combined_child_flow()
    ref = make_ref()

    handle =
      Exec.run_async(
        SystemLoad.combined_flow(),
        %{value: 4, items: [3, 1]},
        runtime_context(context, ref),
        max_concurrency: 2,
        task_supervisor: context.supervisor
      )

    handle_monitor = Process.monitor(handle.pid)

    phases = [[:start], [:child], [:choice], [3, 1], [:reduce], [:reduce], [:iterate], [:iterate]]

    worker_monitors =
      Enum.flat_map(phases, fn expected_ids ->
        workers = take_ready(ref, length(expected_ids))
        assert Enum.sort(Enum.map(workers, &elem(&1, 0))) == Enum.sort(expected_ids)
        monitors = Enum.map(workers, fn {_id, pid} -> {pid, Process.monitor(pid)} end)
        release(ref, workers)
        monitors
      end)

    assert {:ok, result} = Exec.await(handle, 5_000)

    assert result == %{
             child: 4,
             route: 4,
             mapped: [%{id: 3, value: 3}, %{id: 1, value: 1}],
             total: 4,
             iteration: 6
           }

    for {pid, monitor} <- worker_monitors do
      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 5_000
    end

    assert_receive {:DOWN, ^handle_monitor, :process, _, :normal}, 5_000
    ledger = SystemLoad.snapshot(context.ledger)
    assert ledger.active == 0
    assert ledger.peak <= 2

    assert Enum.frequencies(ledger.started) == %{
             3 => 1,
             1 => 1,
             start: 1,
             child: 1,
             choice: 1,
             reduce: 2,
             iterate: 2
           }

    assert Enum.frequencies(ledger.completed) == Enum.frequencies(ledger.started)
    assert Task.Supervisor.children(context.supervisor) == []
    refute_received {^ref, :ready, _, _}
    events = telemetry(context.event_ref)
    ids = for {_event, _measurements, metadata} <- events, do: metadata.execution_id
    assert length(Enum.uniq(ids)) == 1

    assert Enum.all?(events, fn {_event, _, metadata} ->
             metadata.flow == "system_all_components"
           end)

    refute Enum.any?(events, fn {event, _, _} -> List.last(event) == :error end)

    assert event_metadata(events, [:jido, :flow, :start]) |> length() == 1
    assert event_metadata(events, [:jido, :flow, :stop]) |> length() == 1

    assert event_metadata(events, [:jido, :flow, :node, :start])
           |> Enum.map(&{&1.node, &1.kind})
           |> Enum.sort() ==
             Enum.sort([
               {"start", :step},
               {"child", :subflow},
               {"route", :choice},
               {"mapped", :map},
               {"reduce", :reduce},
               {"iterate", :iterate}
             ])

    assert event_metadata(events, [:jido, :flow, :target, :start])
           |> Enum.map(&{&1.node, &1.kind, &1.option, &1.target})
           |> Enum.sort() ==
             Enum.sort([
               {"start", :step, nil, SystemLoad.HeldWork},
               {"child_work", :step, nil, SystemLoad.HeldWork},
               {"route", :choice, "positive", SystemLoad.HeldWork}
             ])

    assert_collection_metadata(events, [:map, :item], "mapped", :map_item, [0, 1])
    assert_collection_metadata(events, [:reduce, :item], "reduce", :reduce_item, [0, 1])

    assert_collection_metadata(
      events,
      [:iterate, :iteration],
      "iterate",
      :iterate_iteration,
      [0, 1]
    )
  end

  test "a nested child failure stops the composed Flow before Choice", context do
    ref = make_ref()

    handle =
      Exec.run_async(
        SystemLoad.combined_flow(),
        %{value: 4, items: [3, 1]},
        runtime_context(context, ref),
        max_concurrency: 2,
        task_supervisor: context.supervisor
      )

    start = take_ready(ref, 1)
    release(ref, start)
    [{:child, child_worker}] = take_ready(ref, 1)
    send(child_worker, {ref, :fail})

    assert {:error, error} = Exec.await(handle, 5_000)
    assert error.details.node_path == ["child", "child_work"]
    assert Enum.sort(SystemLoad.snapshot(context.ledger).started) == [:child, :start]
    refute_received {^ref, :ready, _, _}

    events = telemetry(context.event_ref)
    assert_event_error(events, [:jido, :flow], Jido.Action.Error.ExecutionFailureError)
    assert_event_error(events, [:jido, :flow, :target], Jido.Action.Error.ExecutionFailureError)

    assert Enum.any?(event_metadata(events, [:jido, :flow, :target, :error]), fn metadata ->
             metadata.node == "child_work" and
               metadata.error.details.id == :child and
               metadata.error_type == :execution_error
           end)
  end

  test "a killed admitted worker stops pending work and drains its sibling", context do
    ref = make_ref()

    handle =
      Exec.run_async(
        SystemLoad.wide_flow(6),
        %{},
        runtime_context(context, ref),
        max_concurrency: 2,
        task_supervisor: context.supervisor
      )

    workers = take_ready(ref, 2)
    [{killed_id, killed_pid}, {sibling_id, sibling_pid}] = workers
    killed_monitor = Process.monitor(killed_pid)
    sibling_monitor = Process.monitor(sibling_pid)
    Process.exit(killed_pid, :kill)
    assert_receive {:DOWN, ^killed_monitor, :process, ^killed_pid, :killed}, 5_000
    send(sibling_pid, {ref, :fail})

    assert {:error, %Jido.Flow.Error.ExecutionFailureError{failures: failures}} =
             Exec.await(handle, 5_000)

    assert Enum.map(failures, & &1.error.details.node_path) ==
             [["work_#{killed_id}"], ["work_#{sibling_id}"]]

    assert_receive {:DOWN, ^sibling_monitor, :process, ^sibling_pid, :normal}, 5_000
    assert length(SystemLoad.snapshot(context.ledger).started) == 2
    assert Task.Supervisor.children(context.supervisor) == []
    refute_received {^ref, :ready, _, _}
  end

  test "release, cancellation, and await keep one terminal Flow span", context do
    for mode <- [:release_then_cancel, :release_then_await, :await_timeout] do
      ref = make_ref()

      handle =
        Exec.run_async(
          SystemLoad.wide_flow(1),
          %{},
          runtime_context(context, ref),
          max_concurrency: 1,
          task_supervisor: context.supervisor
        )

      [{1, worker}] = take_ready(ref, 1)
      worker_monitor = Process.monitor(worker)
      handle_monitor = Process.monitor(handle.pid)

      case mode do
        :release_then_cancel ->
          send(worker, {ref, :release})
          assert :ok = Exec.cancel(handle)
          assert {:error, %Jido.Exec.Error.InvalidHandleError{}} = Exec.await(handle, 0)

        :release_then_await ->
          send(worker, {ref, :release})
          assert {:ok, %{values: [1]}} = Exec.await(handle, 5_000)
          assert :ok = Exec.cancel(handle)

        :await_timeout ->
          assert {:error, %Jido.Exec.Error.AsyncTimeoutError{}} = Exec.await(handle, 0)
          assert :ok = Exec.cancel(handle)
      end

      assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _}, 5_000
      assert_receive {:DOWN, ^handle_monitor, :process, _, _}, 5_000
      assert Task.Supervisor.children(context.supervisor) == []
      assert_handle_mailbox_empty(handle)

      events = telemetry(context.event_ref)
      assert length(event_metadata(events, [:jido, :flow, :start])) == 1

      assert length(
               event_metadata(events, [:jido, :flow, :stop]) ++
                 event_metadata(events, [:jido, :flow, :error])
             ) == 1
    end
  end

  test "Action error and complete-call timeout each keep their winning error", context do
    for winner <- [:action_error, :timeout] do
      ref = make_ref()

      handle =
        Exec.run_async(
          SystemLoad.wide_flow(1),
          %{},
          runtime_context(context, ref),
          max_concurrency: 1,
          task_supervisor: context.supervisor,
          timeout: 1_000
        )

      [{1, worker}] = take_ready(ref, 1)
      worker_monitor = Process.monitor(worker)

      if winner == :action_error, do: send(worker, {ref, :fail})

      assert {:error, error} = Exec.await(handle, 5_000)

      if winner == :action_error do
        assert %Jido.Action.Error.ExecutionFailureError{message: "injected held-work failure"} =
                 error
      else
        assert %Jido.Flow.Error.TimeoutError{timeout: 1_000} = error
        send(worker, {ref, :fail})
      end

      assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _}, 5_000
      assert Task.Supervisor.children(context.supervisor) == []
      assert_handle_mailbox_empty(handle)
      events = telemetry(context.event_ref)
      assert length(event_metadata(events, [:jido, :flow, :start])) == 1
      assert length(event_metadata(events, [:jido, :flow, :error])) == 1
      assert event_metadata(events, [:jido, :flow, :stop]) == []
    end
  end

  for terminal <- [:cancel, :timeout], phase <- [:parent, :child] do
    @tag terminal: terminal, phase: phase
    test "#{terminal} at the #{phase} barrier starts no later composed work", context do
      ref = make_ref()
      options = [max_concurrency: 2, task_supervisor: context.supervisor]

      options =
        if context.terminal == :timeout, do: Keyword.put(options, :timeout, 2_000), else: options

      handle =
        Exec.run_async(
          SystemLoad.combined_flow(),
          %{value: 4, items: [3, 1]},
          runtime_context(context, ref),
          options
        )

      handle_monitor = Process.monitor(handle.pid)

      if context.phase == :child do
        start = take_ready(ref, 1)
        release(ref, start)
      end

      [{held_id, held_pid}] = take_ready(ref, 1)
      held_monitor = Process.monitor(held_pid)
      assert held_id == if(context.phase == :parent, do: :start, else: :child)

      if context.terminal == :cancel do
        assert :ok = Exec.cancel(handle)
      else
        assert {:error, %Jido.Flow.Error.TimeoutError{timeout: 2_000}} = Exec.await(handle, 5_000)
      end

      assert_receive {:DOWN, ^held_monitor, :process, ^held_pid, _}, 5_000
      assert_receive {:DOWN, ^handle_monitor, :process, _, _}, 5_000

      expected = if context.phase == :parent, do: [:start], else: [:start, :child]
      assert Enum.sort(SystemLoad.snapshot(context.ledger).started) == Enum.sort(expected)
      assert Task.Supervisor.children(context.supervisor) == []
      refute_received {^ref, :ready, _, _}
    end
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

  test "supervisor loss clears the caller-owned async mailbox", context do
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
    monitors = for {_id, pid} <- workers, do: {pid, Process.monitor(pid)}
    assert :ok = Supervisor.stop(context.supervisor)
    assert {:error, %Jido.Exec.Error.AsyncExecutionError{}} = Exec.await(handle, 5_000)

    for {pid, monitor} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 5_000
    end

    assert_handle_mailbox_empty(handle)
    assert Enum.sort(SystemLoad.snapshot(context.ledger).started) == [:left, :right]
    refute_received {^ref, :ready, _, _}
  end

  for phase <- [:initial_step, :map_fan_out, :map_fan_in, :final_output] do
    @tag phase: phase
    test "owner death at #{phase} stops only admitted composed work", context do
      ref = make_ref()
      observer = self()

      owner =
        spawn(fn ->
          handle =
            Exec.run_async(
              SystemLoad.combined_flow(),
              %{value: 4, items: [3, 1]},
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

      owner_monitor = Process.monitor(owner)
      assert_receive {^ref, :handle, handle}, 5_000
      handle_monitor = Process.monitor(handle.pid)
      {held, expected_started} = hold_combined_phase(ref, context.phase)
      held_monitors = for {_id, pid} <- held, do: {pid, Process.monitor(pid)}
      send(owner, :stop)

      assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}, 5_000
      assert_receive {:DOWN, ^handle_monitor, :process, _, _}, 5_000

      for {pid, monitor} <- held_monitors do
        assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 5_000
      end

      assert Enum.frequencies(SystemLoad.snapshot(context.ledger).started) ==
               Enum.frequencies(expected_started)

      assert Task.Supervisor.children(context.supervisor) == []
      refute_received {^ref, :ready, _, _}
      assert_handle_mailbox_empty(handle)
    end

    @tag phase: phase
    test "supervisor loss at #{phase} does not use global work", context do
      ref = make_ref()
      observer = self()

      caller =
        Task.async(fn ->
          result =
            Exec.run(
              SystemLoad.combined_flow(),
              %{value: 4, items: [3, 1]},
              runtime_context(context, ref, observer),
              max_concurrency: 2,
              task_supervisor: context.supervisor
            )

          send(observer, {ref, :result, result})
          :ok
        end)

      {held, expected_started} = hold_combined_phase(ref, context.phase)
      held_monitors = for {_id, pid} <- held, do: {pid, Process.monitor(pid)}
      assert :ok = Supervisor.stop(context.supervisor)

      for {pid, monitor} <- held_monitors do
        assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 5_000
      end

      assert_receive {^ref, :result, {:error, error}}, 5_000
      assert is_exception(error)
      assert :ok = Task.await(caller, 5_000)

      assert Enum.frequencies(SystemLoad.snapshot(context.ledger).started) ==
               Enum.frequencies(expected_started)

      refute_received {^ref, :ready, _, _}
    end
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

  defp assert_event_error(events, prefix, error_module) do
    errors =
      for {event, _measurements, metadata} <- events,
          event == prefix ++ [:error],
          do: metadata

    assert errors != []
    assert Enum.any?(errors, &match?(%{error: %{__struct__: ^error_module}}, &1))
    assert Enum.all?(errors, &Map.has_key?(&1, :error_type))
  end

  defp event_metadata(events, event) do
    for {^event, _measurements, metadata} <- events, do: metadata
  end

  defp assert_collection_metadata(events, suffix, node, kind, indexes) do
    prefix = [:jido, :flow] ++ suffix
    starts = event_metadata(events, prefix ++ [:start])
    stops = event_metadata(events, prefix ++ [:stop])
    index_key = if kind == :iterate_iteration, do: :iteration_index, else: :item_index
    id_key = if kind == :iterate_iteration, do: :iteration_id, else: :item_id

    assert Enum.map(starts, &Map.fetch!(&1, index_key)) == indexes
    assert length(Enum.uniq(Enum.map(starts, &Map.fetch!(&1, id_key)))) == length(indexes)

    assert Enum.all?(
             starts,
             &(&1.node == node and &1.kind == kind and &1.target == SystemLoad.HeldWork)
           )

    signature = fn metadata ->
      Map.take(metadata, [:node, :kind, id_key, index_key, :state_revision])
    end

    # Parallel Map items can finish in a different order from their starts.
    # Reduce and Iterate still require their serial completion order.
    stops = if kind == :map_item, do: Enum.sort_by(stops, &Map.fetch!(&1, index_key)), else: stops

    assert Enum.map(starts, signature) == Enum.map(stops, signature)
  end

  defp assert_handle_mailbox_empty(handle) do
    {:messages, messages} = Process.info(self(), :messages)

    refute Enum.any?(messages, fn
             {:jido_exec_async_result, ref, pid, _} ->
               ref == handle.ref and pid == handle.pid

             {:DOWN, monitor, :process, pid, _} ->
               monitor == handle.monitor_ref and pid == handle.pid

             _ ->
               false
           end)
  end

  defp hold_combined_phase(ref, phase) do
    waves = [
      {[:start], :initial_step},
      {[:child], nil},
      {[:choice], nil},
      {[3, 1], :map_fan_out},
      {[:reduce], :map_fan_in},
      {[:reduce], nil},
      {[:iterate], nil},
      {[:iterate], :final_output}
    ]

    Enum.reduce_while(waves, [], fn {expected, label}, started ->
      workers = take_ready(ref, length(expected))
      assert Enum.sort(Enum.map(workers, &elem(&1, 0))) == Enum.sort(expected)
      started = expected ++ started

      if phase == label do
        {:halt, {workers, started}}
      else
        release(ref, workers)
        {:cont, started}
      end
    end)
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
