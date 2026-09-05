defmodule Jido.Exec.Telemetry.Tracker do
  @moduledoc false

  use GenServer

  alias Jido.Exec.Telemetry

  @call_timeout 1_000
  @delivery_timeout 100

  @doc false
  @spec start_link() :: GenServer.on_start()
  def start_link do
    GenServer.start_link(__MODULE__, {self(), Logger.metadata()})
  end

  @doc false
  @spec open(pid(), Telemetry.span()) :: :ok | :suppressed
  def open(tracker, span) when is_pid(tracker) do
    GenServer.call(tracker, {:open, span}, @call_timeout)
  catch
    :exit, _reason -> :suppressed
  end

  @doc false
  @spec close(pid(), Telemetry.span(), :stop | :error, map()) :: :ok
  def close(tracker, span, suffix, extra_metadata)
      when is_pid(tracker) and suffix in [:stop, :error] and is_map(extra_metadata) do
    stopped_at = System.monotonic_time()
    GenServer.call(tracker, {:close, span, suffix, extra_metadata, stopped_at}, @call_timeout)
  catch
    :exit, _reason -> :ok
  end

  @doc false
  @spec fail_all(pid(), term()) :: :ok
  def fail_all(tracker, error) when is_pid(tracker) do
    stopped_at = System.monotonic_time()
    GenServer.call(tracker, {:fail_all, error, stopped_at}, @call_timeout)
  catch
    :exit, _reason -> :ok
  end

  @doc false
  @spec stop(pid()) :: :ok
  def stop(tracker) when is_pid(tracker) do
    monitor = Process.monitor(tracker)
    Process.unlink(tracker)

    try do
      GenServer.stop(tracker, :normal, @call_timeout)
    catch
      :exit, _reason -> Process.exit(tracker, :kill)
    end

    await_down(tracker, monitor)
  end

  @impl true
  def init({owner, logger_metadata}) do
    Process.flag(:trap_exit, true)
    Logger.metadata(logger_metadata)
    owner_monitor = Process.monitor(owner)
    tracker = self()

    delivery =
      spawn_link(fn ->
        Logger.metadata(logger_metadata)
        deliver()
      end)

    delivery_guard = spawn(fn -> guard_delivery(tracker, delivery) end)

    {:ok,
     %{
       closed?: false,
       next_order: 0,
       spans: %{},
       delivery: delivery,
       delivery_guard: delivery_guard,
       owner_monitor: owner_monitor
     }}
  end

  @impl true
  def handle_call({:open, _span}, _from, %{closed?: true} = state) do
    {:reply, :suppressed, state}
  end

  def handle_call({:open, span}, _from, state) do
    enqueue(state.delivery, {:start, span})
    order = state.next_order + 1

    {:reply, :ok,
     %{
       state
       | next_order: order,
         spans: Map.put(state.spans, span.id, {order, span})
     }}
  end

  def handle_call({:close, span, suffix, extra_metadata, stopped_at}, _from, state) do
    case Map.pop(state.spans, span.id) do
      {nil, _spans} ->
        {:reply, :ok, state}

      {{_order, open_span}, spans} ->
        enqueue(state.delivery, {:terminal, open_span, suffix, extra_metadata, stopped_at})
        {:reply, :ok, %{state | spans: spans}}
    end
  end

  def handle_call({:fail_all, error, stopped_at}, _from, state) do
    extra_metadata = Telemetry.error_metadata(error)

    state.spans
    |> Map.values()
    |> Enum.sort_by(&elem(&1, 0), :desc)
    |> Enum.each(fn {_order, span} ->
      enqueue(state.delivery, {:terminal, span, :error, extra_metadata, stopped_at})
    end)

    {:reply, :ok, %{state | closed?: true, spans: %{}}}
  end

  @impl true
  def handle_info({:EXIT, delivery, _reason}, %{delivery: delivery} = state) do
    {:noreply, %{state | delivery: nil}}
  end

  # stop/1 unlinks before forced shutdown. The monitor keeps ownership intact
  # if the caller exits during that operation.
  def handle_info({:DOWN, monitor, :process, _owner, _reason}, %{owner_monitor: monitor} = state) do
    {:stop, :normal, state}
  end

  @impl true
  def terminate(_reason, %{delivery: delivery, delivery_guard: guard}) do
    stop_delivery(delivery)
    await_down(guard, Process.monitor(guard))
  end

  defp stop_delivery(nil), do: :ok

  defp stop_delivery(delivery) do
    monitor = Process.monitor(delivery)
    send(delivery, :stop)

    receive do
      {:DOWN, ^monitor, :process, ^delivery, _reason} -> :ok
    after
      @delivery_timeout ->
        Process.exit(delivery, :kill)
        await_down(delivery, monitor)
    end
  end

  # A handler can trap exits. Keep its owner monitor outside handler code so
  # an abrupt tracker exit still stops delivery, even without terminate/2.
  defp guard_delivery(tracker, delivery) do
    tracker_monitor = Process.monitor(tracker)
    delivery_monitor = Process.monitor(delivery)

    receive do
      {:DOWN, ^tracker_monitor, :process, ^tracker, _reason} ->
        Process.exit(delivery, :kill)

      {:DOWN, ^delivery_monitor, :process, ^delivery, _reason} ->
        :ok
    end
  end

  defp enqueue(nil, _event), do: :ok
  defp enqueue(delivery, event), do: send(delivery, event)

  # One sender and one delivery process keep event order. Handler code never
  # runs in the process that owns span records or cancellation.
  defp deliver do
    receive do
      {:start, span} ->
        Telemetry.emit_start(span)
        deliver()

      {:terminal, span, suffix, extra_metadata, stopped_at} ->
        Telemetry.emit_terminal(span, suffix, extra_metadata, stopped_at)
        deliver()

      :stop ->
        :ok
    end
  end

  defp await_down(pid, monitor) do
    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    after
      @call_timeout ->
        Process.demonitor(monitor, [:flush])
        :ok
    end
  end
end
