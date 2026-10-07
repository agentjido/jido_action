defmodule JidoActionTest.Property.Runtime do
  @moduledoc false
  import ExUnit.Assertions

  def with_context(fun) do
    {:ok, supervisor} = Task.Supervisor.start_link()
    context = %{observer: self(), token: make_ref(), supervisor: supervisor}

    try do
      result = fun.(context)
      # An async result can precede controller exit. Confirm termination first.
      assert_supervisor_idle(supervisor)
      result
    after
      try do
        Supervisor.stop(supervisor)
      after
        drain(context.token)
      end
    end
  end

  defp drain(token) do
    receive do
      {^token, _, _, _} -> drain(token)
      {^token, _, _} -> drain(token)
      {^token, _, _, _, _} -> drain(token)
    after
      0 -> :ok
    end
  end

  def options(_context, concurrency \\ 1),
    do: [max_concurrency: concurrency]

  # Read callback messages only after a public completion or mutation barrier.
  def calls(context), do: calls(context.token, [])

  defp calls(token, acc) do
    receive do
      {^token, :call, value, pid} -> calls(token, [{value, pid} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  def assert_calls(context, expected) do
    calls = calls(context)
    assert Enum.map(calls, &elem(&1, 0)) == expected
    assert_workers_stopped(Enum.map(calls, &elem(&1, 1)))
  end

  def assert_workers_stopped(pids) do
    for pid <- Enum.uniq(pids), pid != self() do
      monitor = Process.monitor(pid)

      try do
        assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 1_000
      after
        Process.demonitor(monitor, [:flush])
      end
    end
  end

  def assert_supervisor_idle(supervisor) do
    assert_workers_stopped(Task.Supervisor.children(supervisor))
    # A DOWN message to this process does not confirm that the supervisor has
    # removed the child's entry. Check live processes, not that bookkeeping race.
    refute Enum.any?(Task.Supervisor.children(supervisor), &Process.alive?/1)
  end

  defmodule Emit do
    use Jido.Action, name: "property_emit"
    @impl true
    def run(%{value: value} = params, context) do
      label = Map.get(params, :label, value)
      send(context.observer, {context.token, :call, label, self()})

      if params[:fail],
        do: {:error, {:rejected, value}, [:discard]},
        else: {:ok, %{value: value}, Map.get(params, :effects, [label])}
    end
  end

  defmodule Gate do
    use Jido.Action, name: "property_gate"
    @impl true
    def run(%{value: value}, context) do
      send(context.observer, {context.token, :ready, value, self()})

      receive do
        {token, :release} when token == context.token -> {:ok, %{value: value}, [value]}
        {token, :fail} when token == context.token -> {:error, {:rejected, value}, [:discard]}
      end
    end
  end
end
