defmodule JidoActionTest.Exec.WorkAllocationTest do
  # Function tracing changes a VM-wide trace pattern.
  use ExUnit.Case, async: false

  alias Jido.{Exec, Flow}
  alias Jido.Exec.Work
  alias Jido.Flow.{Ref, Step}
  alias JidoActionTest.Fixtures.Actions.EchoParamsAction

  for mode <- [:run, :async, :continue] do
    test "#{mode} does not construct descriptors when no inspection is requested" do
      flow = parallel_flow()

      {result, count} =
        construction_count(fn supervisor ->
          case unquote(mode) do
            :run ->
              Exec.run(flow, %{}, %{}, task_supervisor: supervisor)

            :async ->
              flow
              |> Exec.run_async(%{}, %{}, task_supervisor: supervisor)
              |> Exec.await(:infinity)

            :continue ->
              {:ok, execution} = Exec.start(flow, %{}, %{}, task_supervisor: supervisor)
              {:ok, completed} = Exec.continue(execution)
              Exec.result(completed)
          end
        end)

      assert result == {:ok, %{}}
      assert count == 0
    end
  end

  test "step constructs only its returned descriptor" do
    flow = parallel_flow()

    {result, count} =
      construction_count(fn supervisor ->
        {:ok, execution} = Exec.start(flow, %{}, %{}, task_supervisor: supervisor)
        {:ok, work, current} = Exec.step(execution)
        {:ok, completed} = Exec.continue(current)
        {work.status, Exec.result(completed)}
      end)

    assert result == {:completed, {:ok, %{}}}
    assert count == 1
  end

  test "wave constructs only admitted descriptors and does not describe later work" do
    flow = parallel_flow()

    {result, count} =
      construction_count(fn supervisor ->
        {:ok, execution} = Exec.start(flow, %{}, %{}, task_supervisor: supervisor)
        {:ok, work, current} = Exec.wave(execution)
        {:ok, completed} = Exec.continue(current)
        {length(work), Exec.result(completed)}
      end)

    assert result == {16, {:ok, %{}}}
    assert count == 16
  end

  defp parallel_flow do
    names = Enum.map(1..16, &"work_#{&1}")
    components = Enum.map(names, &Step.new!(name: &1, action: EchoParamsAction))
    last = Step.new!(name: "last", action: EchoParamsAction, after: names)

    Flow.new!(
      name: "uninspected_work",
      components: components ++ [last],
      output: Ref.result("last")
    )
  end

  defp construction_count(fun) do
    Code.ensure_loaded!(Work)
    owner = self()
    ref = make_ref()
    supervisor = start_supervised!(Task.Supervisor)

    {caller, monitor} =
      spawn_monitor(fn ->
        receive do
          {^ref, :run} ->
            send(owner, {ref, :result, fun.(supervisor)})
            receive do: ({^ref, :stop} -> :ok)
        end
      end)

    try do
      :erlang.trace_pattern({Work, :new, :_}, true, [:local])
      flags = [:call, :arity, :set_on_spawn, {:tracer, self()}]
      :erlang.trace(caller, true, flags)
      :erlang.trace(supervisor, true, flags)
      send(caller, {ref, :run})
      assert_receive {^ref, :result, result}, 5_000
      delivered = :erlang.trace_delivered(:all)
      assert_receive {:trace_delivered, :all, ^delivered}, 1_000
      count = drain_calls(0)
      send(caller, {ref, :stop})
      assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}, 1_000
      {result, count}
    after
      :erlang.trace(supervisor, false, [:all])
      :erlang.trace_pattern({Work, :new, :_}, false, [:local])
      Process.exit(caller, :kill)
      Process.demonitor(monitor, [:flush])
    end
  end

  defp drain_calls(count) do
    receive do
      {:trace, _pid, :call, {Work, :new, _arity}} -> drain_calls(count + 1)
    after
      0 -> count
    end
  end
end
