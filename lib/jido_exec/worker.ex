defmodule Jido.Exec.Worker do
  @moduledoc false

  alias Jido.Exec.Runtime

  @controller_key {__MODULE__, :controller}

  @doc false
  @spec prepare(pid(), reference(), reference() | nil, (-> term())) :: (-> term())
  def prepare(owner, ref, controller, work) do
    group_leader = Process.group_leader()
    metadata = Logger.metadata()

    fn ->
      if await_start(owner, controller || ref) do
        Process.put(@controller_key, controller)
        Process.group_leader(self(), group_leader)
        Logger.metadata(metadata)
        send(ref, {ref, self(), work.()})
      end
    end
  end

  @doc false
  @spec start(Runtime.supervisor_reference(), reference(), (-> term())) ::
          {:ok, pid(), reference()} | {:error, term()}
  def start(supervisor, ref, work) do
    owner = self()
    controller = Process.get(@controller_key)
    work = prepare(owner, ref, controller, work)

    case Runtime.start_child(supervisor, work) do
      {:ok, worker} ->
        monitor = Process.monitor(worker)

        if controller,
          do: send(controller, {controller, :child, worker}),
          else: send(worker, {ref, :run})

        {:ok, worker, monitor}

      {:error, _} = error ->
        error
    end
  end

  defp await_start(owner, ref) do
    # Only startup waits on the parent. Running callbacks can outlive it.
    monitor = Process.monitor(owner)

    receive do
      {^ref, :run} ->
        Process.demonitor(monitor, [:flush])
        true

      {:DOWN, ^monitor, :process, ^owner, _reason} ->
        false
    end
  end

  @doc false
  @spec finish(pid(), reference()) :: :ok
  def finish(worker, monitor) do
    receive do
      {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
    after
      1_000 -> Process.demonitor(monitor, [:flush])
    end

    :ok
  end

  @doc false
  @spec terminate([{pid(), reference()}]) :: :ok
  def terminate(workers) do
    workers =
      for {worker, monitor} <- workers do
        Process.demonitor(monitor, [:flush])
        {worker, Process.monitor(worker)}
      end

    for {worker, _monitor} <- workers, do: Process.exit(worker, :kill)
    for {worker, monitor} <- workers, do: finish(worker, monitor)
    :ok
  end
end
