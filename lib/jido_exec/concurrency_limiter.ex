defmodule Jido.Exec.ConcurrencyLimiter do
  @moduledoc false

  use GenServer

  @type t :: pid()

  @spec with_limiter(String.t(), pos_integer(), boolean(), (-> result)) :: result
        when result: term()
  def with_limiter(_execution_id, _limit, false, fun) when is_function(fun, 0), do: fun.()

  def with_limiter(execution_id, limit, true, fun)
      when is_binary(execution_id) and is_integer(limit) and limit > 0 and is_function(fun, 0) do
    case whereis(execution_id) do
      nil ->
        with_new_limiter(execution_id, limit, fun)

      _limiter ->
        fun.()
    end
  end

  @spec whereis(String.t()) :: t() | nil
  def whereis(execution_id) when is_binary(execution_id) do
    case Registry.lookup(Jido.Exec.ConcurrencyRegistry, execution_id) do
      [{limiter, _value}] -> limiter
      [] -> nil
    end
  end

  @spec start(String.t(), pid(), pos_integer()) :: {:ok, t()} | {:error, term()}
  def start(execution_id, owner, limit)
      when is_binary(execution_id) and is_pid(owner) and is_integer(limit) and limit > 0 do
    DynamicSupervisor.start_child(
      Jido.Exec.ConcurrencySupervisor,
      {__MODULE__, {execution_id, owner, limit}}
    )
  end

  @spec with_permit(t() | nil, (-> result)) :: result when result: term()
  def with_permit(nil, fun) when is_function(fun, 0), do: fun.()

  def with_permit(limiter, fun) when is_pid(limiter) and is_function(fun, 0) do
    :ok = GenServer.call(limiter, :acquire, :infinity)

    try do
      fun.()
    after
      release(limiter)
    end
  end

  @spec stop(t() | nil) :: :ok
  def stop(nil), do: :ok

  def stop(limiter) when is_pid(limiter) do
    case DynamicSupervisor.terminate_child(Jido.Exec.ConcurrencySupervisor, limiter) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  def child_spec({execution_id, owner, limit}) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [{execution_id, owner, limit}]},
      restart: :temporary
    }
  end

  @doc false
  def start_link({execution_id, owner, limit}) do
    GenServer.start_link(
      __MODULE__,
      {owner, limit},
      name: {:via, Registry, {Jido.Exec.ConcurrencyRegistry, execution_id}}
    )
  end

  @impl true
  def init({owner, limit}) do
    owner_monitor = Process.monitor(owner)

    {:ok,
     %{
       limit: limit,
       owner_monitor: owner_monitor,
       holders: %{},
       waiters: :queue.new(),
       monitors: %{owner_monitor => :owner}
     }}
  end

  @impl true
  def handle_call(:acquire, {pid, _tag} = from, state) do
    if map_size(state.holders) < state.limit do
      {:reply, :ok, add_holder(state, pid)}
    else
      monitor = Process.monitor(pid)
      waiters = :queue.in({from, pid, monitor}, state.waiters)
      monitors = Map.put(state.monitors, monitor, {:waiter, pid})
      {:noreply, %{state | waiters: waiters, monitors: monitors}}
    end
  end

  def handle_call({:release, pid}, _from, state) do
    state = state |> remove_holder(pid) |> grant_waiters()
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{owner_monitor: monitor} = state) do
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, monitor, :process, pid, _reason}, state) do
    state =
      case Map.get(state.monitors, monitor) do
        {:holder, ^pid} ->
          state
          |> remove_holder(pid, false)
          |> grant_waiters()

        {:waiter, ^pid} ->
          remove_waiter(state, monitor)

        _other ->
          state
      end

    {:noreply, state}
  end

  defp release(limiter) do
    if Process.alive?(limiter) do
      GenServer.call(limiter, {:release, self()}, :infinity)
    else
      :ok
    end
  catch
    :exit, _reason -> :ok
  end

  defp with_new_limiter(execution_id, limit, fun) do
    case start(execution_id, self(), limit) do
      {:ok, limiter} ->
        try do
          fun.()
        after
          stop(limiter)
        end

      {:error, {:already_started, _limiter}} ->
        fun.()

      {:error, reason} ->
        raise "could not start concurrency limiter: #{inspect(reason)}"
    end
  end

  defp add_holder(state, pid, monitor \\ nil) do
    monitor = monitor || Process.monitor(pid)

    %{
      state
      | holders: Map.put(state.holders, pid, monitor),
        monitors: Map.put(state.monitors, monitor, {:holder, pid})
    }
  end

  defp remove_holder(state, pid, demonitor? \\ true) do
    case Map.pop(state.holders, pid) do
      {nil, _holders} ->
        state

      {monitor, holders} ->
        if demonitor?, do: Process.demonitor(monitor, [:flush])
        %{state | holders: holders, monitors: Map.delete(state.monitors, monitor)}
    end
  end

  defp grant_waiters(state) when map_size(state.holders) >= state.limit, do: state

  defp grant_waiters(state) do
    case :queue.out(state.waiters) do
      {:empty, _waiters} ->
        state

      {{:value, {from, pid, monitor}}, waiters} ->
        state = %{state | waiters: waiters}

        if Process.alive?(pid) do
          GenServer.reply(from, :ok)
          add_holder(state, pid, monitor)
        else
          Process.demonitor(monitor, [:flush])

          state
          |> Map.update!(:monitors, &Map.delete(&1, monitor))
          |> grant_waiters()
        end
    end
  end

  defp remove_waiter(state, monitor) do
    waiters =
      state.waiters
      |> :queue.to_list()
      |> Enum.reject(fn {_from, _pid, waiter_monitor} -> waiter_monitor == monitor end)
      |> :queue.from_list()

    %{state | waiters: waiters, monitors: Map.delete(state.monitors, monitor)}
  end
end
