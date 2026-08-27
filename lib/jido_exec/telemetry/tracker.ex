defmodule Jido.Exec.Telemetry.Tracker do
  @moduledoc false

  use GenServer

  alias Jido.Exec.Telemetry

  @doc false
  @spec start_link() :: GenServer.on_start()
  def start_link do
    GenServer.start_link(__MODULE__, :ok)
  end

  @doc false
  @spec open(pid(), Telemetry.span()) :: :ok | :suppressed
  def open(tracker, span) when is_pid(tracker) do
    GenServer.call(tracker, {:open, span}, :infinity)
  catch
    :exit, _reason -> :suppressed
  end

  @doc false
  @spec close(pid(), Telemetry.span(), :stop | :error, map()) :: :ok
  def close(tracker, span, suffix, extra_metadata)
      when is_pid(tracker) and suffix in [:stop, :error] and is_map(extra_metadata) do
    GenServer.call(tracker, {:close, span, suffix, extra_metadata}, :infinity)
  catch
    :exit, _reason -> :ok
  end

  @doc false
  @spec fail_all(pid(), term()) :: :ok
  def fail_all(tracker, error) when is_pid(tracker) do
    GenServer.call(tracker, {:fail_all, error}, :infinity)
  catch
    :exit, _reason -> :ok
  end

  @doc false
  @spec stop(pid()) :: :ok
  def stop(tracker) when is_pid(tracker) do
    GenServer.stop(tracker, :normal, :infinity)
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def init(:ok), do: {:ok, %{closed?: false, next_order: 0, spans: %{}}}

  @impl true
  def handle_call({:open, _span}, _from, %{closed?: true} = state) do
    {:reply, :suppressed, state}
  end

  def handle_call({:open, span}, _from, state) do
    Telemetry.emit_start(span)
    order = state.next_order + 1

    {:reply, :ok,
     %{
       state
       | next_order: order,
         spans: Map.put(state.spans, span.id, {order, span})
     }}
  end

  def handle_call({:close, span, suffix, extra_metadata}, _from, state) do
    case Map.pop(state.spans, span.id) do
      {nil, _spans} ->
        {:reply, :ok, state}

      {{_order, open_span}, spans} ->
        Telemetry.emit_terminal(open_span, suffix, extra_metadata)
        {:reply, :ok, %{state | spans: spans}}
    end
  end

  def handle_call({:fail_all, error}, _from, state) do
    extra_metadata = Telemetry.error_metadata(error)

    state.spans
    |> Map.values()
    |> Enum.sort_by(&elem(&1, 0), :desc)
    |> Enum.each(fn {_order, span} ->
      Telemetry.emit_terminal(span, :error, extra_metadata)
    end)

    {:reply, :ok, %{state | closed?: true, spans: %{}}}
  end
end
