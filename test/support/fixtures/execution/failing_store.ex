defmodule JidoActionTest.Fixtures.Execution.FailingStore do
  @moduledoc false
  @behaviour Runic.Runner.Store

  def start_link(_), do: Agent.start_link(fn -> %{fail?: false, events: %{}, logs: %{}} end)
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  def fail(agent, fail?), do: Agent.update(agent, &%{&1 | fail?: fail?})

  @impl true
  def init_store(opts), do: {:ok, Keyword.fetch!(opts, :agent)}

  @impl true
  def save(id, log, agent) do
    Agent.get_and_update(agent, fn
      %{fail?: true} = state -> {{:error, :storage_unavailable}, state}
      state -> {:ok, %{state | logs: Map.put(state.logs, id, log)}}
    end)
  end

  @impl true
  def load(id, agent), do: Agent.get(agent, &fetch(&1.logs, id))

  @impl true
  def append(id, events, agent) do
    Agent.get_and_update(agent, fn
      %{fail?: true} = state ->
        {{:error, :storage_unavailable}, state}

      state ->
        all = Map.get(state.events, id, []) ++ events
        {{:ok, length(all)}, %{state | events: Map.put(state.events, id, all)}}
    end)
  end

  @impl true
  def stream(id, agent), do: Agent.get(agent, &fetch(&1.events, id))

  defp fetch(values, id) do
    case Map.fetch(values, id) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :not_found}
    end
  end
end
