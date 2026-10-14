defmodule JidoActionTest.Property.Managed do
  @moduledoc false
  import ExUnit.Assertions
  alias Jido.Exec
  alias JidoActionTest.Property.Runtime

  defmodule Scheduler do
    @behaviour Runic.Runner.Scheduler
    @impl true
    def init(options), do: {:ok, Keyword.fetch!(options, :observer)}
    @impl true
    defdelegate plan_dispatch(workflow, runnables, observer), to: Runic.Runner.Scheduler.Default
    @impl true
    def on_complete(_unit, _duration, {owner, token} = observer) do
      send(owner, {token, :unit_done})
      observer
    end
  end

  def scheduler(token), do: [scheduler: Scheduler, scheduler_opts: [observer: {self(), token}]]

  def with_execution(context, target, params, options, assertion) do
    token = Integer.to_string(System.unique_integer([:positive]))
    id = "fuzz-" <> token
    runtime = %{observer: context.observer, token: token}
    options = Keyword.put(options, :hooks, hooks(token)) ++ scheduler(token)
    assert {:ok, worker} = Exec.start(context.runner, id, target, params, runtime, options)

    try do
      assertion.(id, runtime, options)
    after
      case Runic.Runner.stop(context.runner, id) do
        :ok -> :ok
        {:error, :not_found} -> :ok
      end

      Runtime.assert_workers_stopped([worker])
      drain(token)
    end
  end

  def hooks(token) do
    owner = self()

    [
      on_complete: fn runnable, _duration, _state ->
        controlled_done(owner, token, runnable)
      end,
      on_failed: fn runnable, _reason, _state ->
        controlled_done(owner, token, runnable)
      end,
      on_idle: fn _state -> send(owner, {token, :idle}) end
    ]
  end

  defp controlled_done(owner, token, runnable) do
    case runnable.node do
      %Jido.Exec.Node.Action{instruction: %{target: target}} ->
        if function_exported?(target, :controlled?, 0),
          do: send(owner, {token, :controlled_done, runnable.status})

      _ ->
        :ok
    end
  end

  def complete(runner, id, token, mode) do
    case mode do
      :automatic -> assert_receive {^token, :idle}, 5_000
      :manual -> steps(runner, id, token, 200)
    end

    Exec.result(runner, id)
  end

  def step(runner, id, token) do
    case Exec.step(runner, id) do
      {:ok, %Runic.Workflow{} = workflow} ->
        assert_receive {^token, :unit_done}, 5_000
        {:ok, workflow}

      {:complete, %Runic.Workflow{} = workflow} ->
        {:complete, workflow}
    end
  end

  defp steps(_runner, _id, _token, 0), do: flunk("managed execution exceeded its unit bound")

  defp steps(runner, id, token, remaining) do
    case step(runner, id, token) do
      {:ok, _workflow} -> steps(runner, id, token, remaining - 1)
      {:complete, _workflow} -> :ok
    end
  end

  def calls(token, acc \\ []) do
    receive do
      {^token, :call, label, pid} -> calls(token, [{label, pid} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  def drain(token) do
    receive do
      message when is_tuple(message) and elem(message, 0) == token -> drain(token)
    after
      0 -> :ok
    end
  end
end
