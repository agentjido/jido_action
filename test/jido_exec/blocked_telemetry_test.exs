defmodule JidoActionTest.Exec.BlockedTelemetryTest do
  use ExUnit.Case, async: false
  alias Jido.Exec

  defmodule Probe do
    use Jido.Action, name: "synchronous_telemetry_probe"

    def run(_, %{owner: owner, token: token}) do
      send(owner, {token, :work, self()})
      {:ok, %{worker: self()}}
    end
  end

  setup do
    supervisor = start_supervised!(Task.Supervisor)
    token = make_ref()
    %{supervisor: supervisor, token: token}
  end

  for mode <- [:direct, :timed, :async] do
    @tag mode: mode
    test "#{mode} telemetry runs in the execution lifecycle process", context do
      %{mode: mode, supervisor: supervisor, token: token} = context
      attach(token, :none)
      opts = [task_supervisor: supervisor]
      opts = if mode == :timed, do: [timeout: 5_000] ++ opts, else: opts
      ctx = %{owner: self(), token: token}

      result =
        if mode == :async,
          do: Exec.await(Exec.run_async(Probe, %{}, ctx, opts)),
          else: Exec.run(Probe, %{}, ctx, opts)

      assert {:ok, %{worker: worker}} = result
      emitter = worker
      assert_receive {^token, :event, :start, ^emitter}
      assert_receive {^token, :work, ^worker}
      assert_receive {^token, :event, :stop, ^emitter}
    end
  end

  for terminal <- [:timeout, :cancel] do
    @tag terminal: terminal
    test "#{terminal} stops a worker blocked in a start handler", context do
      %{terminal: terminal, supervisor: supervisor, token: token} = context
      attach(token, :start)

      handle =
        Exec.run_async(Probe, %{}, %{owner: self(), token: token},
          task_supervisor: supervisor,
          timeout: if(terminal == :timeout, do: 500, else: :infinity)
        )

      on_exit(fn -> Process.exit(handle.pid, :kill) end)
      assert_receive {^token, :event, :start, worker}, 1_000
      monitor = Process.monitor(worker)

      if terminal == :cancel do
        assert :ok = Exec.cancel(handle)
      else
        assert {:error, %Jido.Action.Error.TimeoutError{}} = Exec.await(handle, 2_000)
      end

      assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
      assert_receive {^token, :event, :error, _controller}
      refute_received {^token, :work, _}
      assert Task.Supervisor.children(supervisor) == []
    end
  end

  test "a terminal handler holds the worker until the handler returns", context do
    %{supervisor: supervisor, token: token} = context
    attach(token, :stop)

    handle =
      Exec.run_async(Probe, %{}, %{owner: self(), token: token}, task_supervisor: supervisor)

    on_exit(fn -> Process.exit(handle.pid, :kill) end)
    assert_receive {^token, :work, worker}, 1_000
    assert_receive {^token, :event, :stop, handler}, 1_000
    assert handler == worker
    refute_received {:jido_exec_async_result, _, _, _}
    send(worker, {token, :release})
    assert {:ok, %{worker: ^worker}} = Exec.await(handle)
    assert Task.Supervisor.children(supervisor) == []
  end

  defp attach(token, blocked) do
    events = for suffix <- [:start, :stop, :error], do: [:jido, :action, suffix]
    :ok = :telemetry.attach_many(token, events, &__MODULE__.event/4, {self(), token, blocked})
    on_exit(fn -> :telemetry.detach(token) end)
  end

  def event([:jido, :action, suffix], _, _, {owner, token, blocked}) do
    if suffix == blocked, do: Process.flag(:trap_exit, true)
    send(owner, {token, :event, suffix, self()})

    if suffix == blocked do
      receive do: ({^token, :release} -> :ok)
    end
  end
end
