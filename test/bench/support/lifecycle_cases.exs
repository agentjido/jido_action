defmodule JidoActionBench.Block do
  @moduledoc false
  use Jido.Action, name: "benchmark_block"

  @impl true
  def run(_params, %{bench_owner: owner, bench_tag: tag}) do
    send(owner, {tag, :ready, self()})
    receive do: ({^tag, :release} -> {:ok, %{value: 42}})
  end
end

defmodule JidoActionBench.LifecycleCases do
  @moduledoc false
  alias Jido.Exec
  alias JidoActionBench.{Block, ComponentCases, Echo, Fixtures}
  @opts [task_supervisor: JidoActionBench.TaskSupervisor]

  def workloads do
    Enum.map([:cancel, :await_timeout, :call_timeout, :caller_exit], &termination/1) ++
      Enum.map([0, 1_000], &mailbox/1) ++
      Enum.map([:none, :fast, :blocked], &telemetry/1)
  end

  defp termination(mode) do
    %{
      id: "lifecycle/#{mode}",
      setup: fn context -> context end,
      run: fn context -> terminate(mode, context) end,
      check: fn :ok -> :ok end,
      retained: fn _, result -> %{result: result} end
    }
  end

  defp terminate(:caller_exit, context) do
    parent = self()
    tag = make_ref()

    {owner, owner_ref} =
      spawn_monitor(fn ->
        handle = Exec.run_async(Block, %{}, %{bench_owner: parent, bench_tag: tag}, @opts)
        send(parent, {tag, :handle, handle.pid})
        receive do: ({^tag, :hold} -> :ok)
      end)

    try do
      worker = ready(tag)
      worker_ref = Process.monitor(worker)
      managed = receive do: ({^tag, :handle, pid} -> pid)
      managed_ref = Process.monitor(managed)
      Fixtures.barrier(context)
      Process.exit(owner, :kill)
      down(owner, owner_ref)
      down(worker, worker_ref)
      down(managed, managed_ref)
    after
      Process.exit(owner, :kill)
      Process.demonitor(owner_ref, [:flush])
    end
  end

  defp terminate(mode, context) do
    tag = make_ref()
    opts = if mode == :call_timeout, do: Keyword.put(@opts, :timeout, 100), else: @opts
    handle = Exec.run_async(Block, %{}, %{bench_owner: self(), bench_tag: tag}, opts)
    worker = ready(tag)
    ref = Process.monitor(worker)
    Fixtures.barrier(context)

    try do
      case mode do
        :cancel ->
          :ok = Exec.cancel(handle)

        :await_timeout ->
          {:error, %Jido.Exec.Error.AsyncTimeoutError{}} = Exec.await(handle, 0)

        :call_timeout ->
          {:error, %Jido.Action.Error.TimeoutError{}} = Exec.await(handle, :infinity)
      end

      down(worker, ref)
    after
      if Process.alive?(handle.pid), do: Exec.cancel(handle)
      Process.demonitor(ref, [:flush])
    end
  end

  defp mailbox(count) do
    %{
      id: "caller/mailbox/#{count}",
      setup: fn context ->
        tag = make_ref()
        for _ <- List.duplicate(:message, count), do: send(self(), {tag, :unrelated})
        {context, tag}
      end,
      run: fn {context, tag} ->
        result =
          Enum.reduce(1..20, nil, fn _, _ ->
            handle = Exec.run_async(Echo, %{value: 42}, context, @opts)
            {:ok, %{value: 42}} = Exec.await(handle, :infinity)
          end)

        {result, tag}
      end,
      check: fn {result, tag} ->
        ComponentCases.expect!(result, {:ok, %{value: 42}})

        for _ <- List.duplicate(:message, count) do
          receive do
            {^tag, :unrelated} -> :ok
          after
            0 -> raise "unrelated caller message was lost"
          end
        end

        receive do
          {:jido_exec_async_result, _, _, _} -> raise "stale async result"
          {:DOWN, _, :process, _, _} -> raise "stale async monitor"
        after
          0 -> :ok
        end
      end,
      retained: fn _, {result, _} -> %{result: result} end
    }
  end

  defp telemetry(mode) do
    flow = Fixtures.graph(:parallel, 16)
    expected = {:ok, Map.new(1..16, &{"s#{&1}", %{value: 42}})}

    %{
      id: "telemetry/#{mode}/16",
      setup: fn context -> context end,
      run: fn context ->
        id = {__MODULE__, make_ref()}

        if mode != :none do
          :ok =
            :telemetry.attach_many(
              id,
              [
                [:jido, :flow, :start],
                [:jido, :flow, :stop],
                [:jido, :flow, :node, :start],
                [:jido, :flow, :node, :stop]
              ],
              &__MODULE__.handle_event/4,
              %{mode: mode, owner: self(), tag: id}
            )
        end

        try do
          handle = Exec.run_async(flow, %{value: 42}, context, @opts)

          if mode == :blocked do
            receive do
              {^id, :handler, handler} ->
                Fixtures.barrier(context)
                send(handler, {id, :release})
            after
              30_000 -> raise "telemetry handler did not start"
            end
          end

          Exec.await(handle, :infinity)
        after
          if mode != :none, do: :telemetry.detach(id)
        end
      end,
      check: &ComponentCases.expect!(&1, expected),
      retained: fn _, result -> %{result: result} end
    }
  end

  def handle_event([:jido, :flow, :start], _, _, %{mode: :blocked, owner: owner, tag: tag}) do
    send(owner, {tag, :handler, self()})
    receive do: ({^tag, :release} -> :ok)
  end

  def handle_event(_, _, _, _), do: :ok

  defp ready(tag) do
    receive do
      {^tag, :ready, worker} -> worker
    after
      30_000 -> raise "benchmark worker did not start"
    end
  end

  defp down(pid, ref) do
    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      30_000 -> raise "benchmark worker did not stop"
    end
  end
end
