defmodule JidoActionBench.Measure do
  @moduledoc false
  @timeout 30_000

  def timing(workload, warmup, samples) do
    isolated(fn ->
      for _ <- 1..warmup, do: invoke(workload)

      measurements =
        for _ <- 1..samples do
          prepared = workload.setup.(%{})
          {:reductions, before_reductions} = Process.info(self(), :reductions)
          before_time = System.monotonic_time()
          result = workload.run.(prepared)
          elapsed = System.monotonic_time() - before_time
          {:reductions, after_reductions} = Process.info(self(), :reductions)
          :ok = workload.check.(result)

          {System.convert_time_unit(elapsed, :native, :nanosecond),
           after_reductions - before_reductions}
        end

      %{
        wall_ns: distribution(Enum.map(measurements, &elem(&1, 0))),
        caller_reductions: distribution(Enum.map(measurements, &elem(&1, 1)))
      }
    end)
  end

  def resources(workload) do
    isolated(fn -> trace_resources(workload) end)
  end

  def term_size(term) do
    word = :erlang.system_info(:wordsize)
    local = :erts_debug.size(term) * word
    flat = :erts_debug.flat_size(term) * word

    # Bound the flattened heap before the transfer. Shared binary payloads do
    # not form part of this heap estimate; the encoded size reports them too.
    if flat > 64 * 1_048_576, do: raise("term transfer exceeds the 64 MiB heap bound")

    transfer =
      isolated(
        fn ->
          receive do
            {:term, copied} ->
              {:memory, memory} = Process.info(self(), :memory)

              %{
                copied_flat_heap_bytes: :erts_debug.flat_size(copied) * word,
                receiver_memory_bytes: memory
              }
          end
        end,
        fn pid -> send(pid, {:term, term}) end
      )

    Map.merge(transfer, %{
      local_heap_bytes: local,
      flat_heap_bytes: flat,
      external_bytes: :erlang.external_size(term)
    })
  end

  def distribution(values) do
    sorted = Enum.sort(values)
    count = length(sorted)

    %{
      samples: values,
      min: hd(sorted),
      median: Enum.at(sorted, div(count, 2)),
      p95: Enum.at(sorted, max(ceil(count * 0.95) - 1, 0)),
      max: List.last(sorted),
      mean: Enum.sum(sorted) / count
    }
  end

  defp invoke(workload) do
    result = workload.run.(workload.setup.(%{}))
    :ok = workload.check.(result)
  end

  defp trace_resources(workload) do
    observer = self()
    table = :ets.new(:bench_owned, [:set, :private])

    supervisor =
      Process.whereis(JidoActionBench.TaskSupervisor) || raise "benchmark supervisor missing"

    {caller, caller_ref} =
      spawn_monitor(fn ->
        receive do
          :bench_go ->
            try do
              result = workload.run.(workload.setup.(%{bench_observer: observer}))
              :ok = workload.check.(result)
              send(observer, {:bench_result, :ok})
            rescue
              error -> send(observer, {:bench_result, {:error, Exception.message(error)}})
            catch
              kind, reason -> send(observer, {:bench_result, {:error, inspect({kind, reason})}})
            end
        end
      end)

    state = %{
      caller: caller,
      caller_ref: caller_ref,
      table: table,
      pending: [],
      result: nil,
      caller_down: false,
      observations: 0,
      observed_peak: %{
        process_memory_bytes: 0,
        process_heap_bytes: 0,
        shared_binary_bytes: 0,
        vm_total_bytes: 0,
        vm_processes_bytes: 0,
        vm_binary_bytes: 0,
        live_owned: 0
      }
    }

    try do
      flags = [:procs, :set_on_spawn, {:tracer, self()}]
      :erlang.trace(supervisor, true, flags)
      :erlang.trace(caller, true, flags)
      state = observe(state)
      send(caller, :bench_go)
      state = collect(state)
      state = finish_owned(state)

      case state.result do
        :ok -> :ok
        other -> raise "resource caller failed: #{inspect(other)}"
      end

      %{
        owned_process_starts: :ets.info(table, :size),
        owned_remaining: 0,
        observations: state.observations,
        observed_peak: state.observed_peak,
        helper_reductions: nil,
        exact_peak_bytes: nil
      }
    after
      :erlang.trace(supervisor, false, [:all])
      Process.exit(caller, :kill)
      Process.demonitor(caller_ref, [:flush])
      # On a failed probe, also stop all observed descendants. Discard this
      # probe's mailbox by ending its isolated observer process.
      for {pid, ref} <- :ets.tab2list(table) do
        Process.exit(pid, :kill)
        Process.demonitor(ref, [:flush])
      end

      :ets.delete(table)
    end
  end

  defp collect(%{caller_down: true} = state), do: fence(state) |> observe()

  defp collect(state) do
    receive do
      message ->
        state = handle(message, state)
        state = if state.pending == [], do: state, else: release_barriers(state)
        collect(state)
    after
      @timeout -> raise "resource caller exceeded the safety limit"
    end
  end

  defp release_barriers(state) do
    state = state |> fence() |> observe()
    for {pid, ref} <- state.pending, do: send(pid, {:bench_release, ref})
    %{state | pending: []}
  end

  defp fence(state) do
    marker = :erlang.trace_delivered(:all)
    drain(marker, state)
  end

  defp drain(marker, state) do
    receive do
      {:trace_delivered, :all, ^marker} -> state
      message -> drain(marker, handle(message, state))
    after
      @timeout -> raise "trace delivery barrier missing"
    end
  end

  defp handle({:trace, _parent, :spawn, child, _mfa}, state) do
    :ets.insert_new(state.table, {child, Process.monitor(child)})
    state
  end

  defp handle({:bench_barrier, pid, ref}, state),
    do: %{state | pending: [{pid, ref} | state.pending]}

  defp handle({:bench_result, result}, state), do: %{state | result: result}

  defp handle({:DOWN, ref, :process, _pid, reason}, %{caller_ref: ref} = state) do
    result = if reason == :normal, do: state.result, else: {:error, inspect(reason)}
    %{state | caller_down: true, result: result}
  end

  defp handle(_message, state), do: state

  defp finish_owned(state) do
    previous = :ets.info(state.table, :size)

    for {pid, _ref} <- :ets.tab2list(state.table) do
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        @timeout -> raise "owned process did not stop: #{inspect(pid)}"
      end
    end

    state = fence(state)
    if :ets.info(state.table, :size) == previous, do: state, else: finish_owned(state)
  end

  defp observe(state) do
    owned = :ets.tab2list(state.table) |> Enum.map(&elem(&1, 0))
    processes = [state.caller | owned]

    infos =
      Enum.flat_map(processes, fn pid ->
        case Process.info(pid, [:memory, :total_heap_size, :binary]) do
          nil -> []
          info -> [info]
        end
      end)

    binaries = infos |> Enum.flat_map(&Keyword.fetch!(&1, :binary))
    binary_sizes = Map.new(binaries, fn {id, bytes, _refs} -> {id, bytes} end)
    vm = :erlang.memory()

    values = %{
      process_memory_bytes: Enum.sum(Enum.map(infos, &Keyword.fetch!(&1, :memory))),
      process_heap_bytes:
        Enum.sum(Enum.map(infos, &Keyword.fetch!(&1, :total_heap_size))) *
          :erlang.system_info(:wordsize),
      shared_binary_bytes: binary_sizes |> Map.values() |> Enum.sum(),
      vm_total_bytes: vm[:total],
      vm_processes_bytes: vm[:processes],
      vm_binary_bytes: vm[:binary],
      live_owned: Enum.count(owned, &Process.alive?/1)
    }

    peaks = Map.merge(state.observed_peak, values, fn _key, old, new -> max(old, new) end)
    %{state | observations: state.observations + 1, observed_peak: peaks}
  end

  defp isolated(fun, start \\ fn _pid -> :ok end) do
    parent = self()
    tag = make_ref()

    {pid, ref} =
      spawn_monitor(fn ->
        result =
          try do
            {:ok, fun.()}
          rescue
            error -> {:error, error, __STACKTRACE__}
          end

        send(parent, {tag, result})
      end)

    try do
      start.(pid)

      result =
        receive do
          {^tag, result} ->
            result

          {:DOWN, ^ref, :process, ^pid, reason} ->
            raise "benchmark process failed: #{inspect(reason)}"
        after
          120_000 -> raise "benchmark exceeded the safety limit"
        end

      receive do
        {:DOWN, ^ref, :process, ^pid, :normal} -> :ok
      after
        @timeout -> raise "benchmark process did not stop"
      end

      case result do
        {:ok, value} -> value
        {:error, error, stacktrace} -> reraise error, stacktrace
      end
    after
      Process.exit(pid, :kill)
      Process.demonitor(ref, [:flush])
    end
  end
end
