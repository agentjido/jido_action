defmodule JidoActionTest.Exec.ActionTaskIsolationTest do
  use ExUnit.Case, async: true
  import JidoActionTest.ProcessCleanup

  alias Jido.{Exec, Instruction}
  alias Jido.Flow.{Ref}

  @moduletag capture_log: true

  defmodule Held do
    use Jido.Action, name: "task_isolation_held"

    @impl true
    def run(_params, %{owner: owner, ref: ref}) do
      send(owner, {ref, :ready, self()})
      receive do: ({^ref, :release} -> {:ok, %{}})
    end
  end

  for timeout <- [:infinity, 5_000], kind <- [:action, :flow] do
    test "#{kind} keeps an exception-valued Task exit reason with timeout #{timeout}" do
      supervisor = start_supervised!(Task.Supervisor)
      owner = self()
      ref = make_ref()

      target =
        if unquote(kind) == :action do
          Held
        else
          JidoActionTest.FlowBuilder.new!(
            name: "hard_task_exit",
            components: [JidoActionTest.FlowComponent.step!(name: "held", action: Held)],
            output: Ref.result("held")
          )
        end

      caller =
        Task.Supervisor.async_nolink(supervisor, fn ->
          Exec.run(target, %{}, %{owner: owner, ref: ref},
            task_supervisor: supervisor,
            timeout: unquote(timeout)
          )
        end)

      assert_receive {^ref, :ready, worker}, 1_000
      monitor = Process.monitor(worker)
      reason = ArgumentError.exception("external Task exit")
      Process.exit(worker, reason)
      assert_receive {:DOWN, ^monitor, :process, ^worker, ^reason}, 1_000
      assert {:error, %Jido.Action.Error.InternalError{} = error} = Task.await(caller)
      assert error.details.reason == reason
      refute Jido.Action.Error.retryable?(error)
      assert_supervisor_quiescent(supervisor)
    end
  end

  defmodule Probe do
    use Jido.Action, name: "task_isolation_probe"

    @impl true
    def run(_params, context) do
      {:ok, observe(context)}
    end

    def observe(context) do
      before = Process.put(:action_task_state, :action)
      logger_before = Logger.metadata()[:action_task_state]
      trapping_before = Process.flag(:trap_exit, true)
      group_leader_before = Process.group_leader()
      metadata_key = :action_task_state
      Logger.metadata([{metadata_key, :action}])
      send(self(), :action_task_message)

      if replacement = context[:replacement_group_leader],
        do: Process.group_leader(self(), replacement)

      %{
        pid: self(),
        before: before,
        logger_before: logger_before,
        trapping_before: trapping_before,
        group_leader_before: group_leader_before
      }
    end
  end

  defmodule Chain do
    use Jido.Action, name: "task_isolation_chain"

    @impl true
    def run(%{left: left, outputs: outputs}, context) do
      output = Probe.observe(context)
      output = Map.put(output, :deadline, context.__jido_exec__.deadline)
      outputs = [output | outputs]

      if left == 0,
        do: {:ok, %{outputs: Enum.reverse(outputs)}},
        else: {:continue, %{left: left - 1, outputs: outputs}, __MODULE__}
    end
  end

  for timeout <- [:infinity, 5_000], mode <- [:sync, :async] do
    test "#{mode} continuations use distinct Tasks and one deadline with timeout #{timeout}" do
      supervisor = start_supervised!(Task.Supervisor)
      replacement = start_supervised!({Agent, fn -> nil end})
      original_group_leader = Process.group_leader()
      Process.put(:action_task_state, :caller)
      metadata_key = :action_task_state
      Logger.metadata([{metadata_key, :caller}])
      opts = [timeout: unquote(timeout), task_supervisor: supervisor]
      input = %{left: 2, outputs: []}

      result =
        if unquote(mode) == :sync,
          do: Exec.run(Chain, input, %{replacement_group_leader: replacement}, opts),
          else:
            Chain
            |> Exec.run_async(input, %{replacement_group_leader: replacement}, opts)
            |> Exec.await()

      assert {:ok, %{outputs: outputs}} = result
      Enum.each(outputs, &assert_isolated/1)
      assert outputs |> Enum.map(& &1.pid) |> Enum.uniq() |> length() == 3
      assert Enum.all?(outputs, &(&1.group_leader_before == original_group_leader))
      assert Enum.all?(outputs, &is_nil(&1.logger_before))
      assert [deadline] = outputs |> Enum.map(& &1.deadline) |> Enum.uniq()

      assert if(unquote(timeout) == :infinity,
               do: deadline == :infinity,
               else: is_integer(deadline)
             )

      assert Process.get(:action_task_state) == :caller
      assert Logger.metadata()[:action_task_state] == :caller
      assert_supervisor_quiescent(supervisor)
      refute_received :action_task_message
    end
  end

  for timeout <- [:infinity, 5_000], form <- [:action, :instruction] do
    test "#{form} uses a fresh supervised Task with timeout #{timeout}" do
      supervisor = start_supervised!(Task.Supervisor)
      Process.put(:action_task_state, :caller)
      metadata_key = :action_task_state
      Logger.metadata([{metadata_key, :caller}])
      before = Process.info(self(), [:monitors, :trap_exit])
      target = if unquote(form) == :action, do: Probe, else: Instruction.new!(target: Probe)

      workers =
        for _ <- 1..2 do
          assert {:ok, output} =
                   Exec.run(target, %{}, %{},
                     task_supervisor: supervisor,
                     timeout: unquote(timeout)
                   )

          assert_isolated(output)
          output.pid
        end

      assert length(Enum.uniq(workers)) == 2
      assert Process.get(:action_task_state) == :caller
      assert Logger.metadata()[:action_task_state] == :caller
      assert Process.info(self(), [:monitors, :trap_exit]) == before
      assert_supervisor_quiescent(supervisor)
      refute_received :action_task_message
    end
  end

  for timeout <- [:infinity, 5_000], concurrency <- [1, 2] do
    test "Flow Actions use distinct Tasks with timeout #{timeout} and concurrency #{concurrency}" do
      supervisor = start_supervised!(Task.Supervisor)

      {:ok, outputs} =
        Exec.run(flow(), %{}, %{},
          timeout: unquote(timeout),
          max_concurrency: unquote(concurrency),
          task_supervisor: supervisor
        )

      assert_flow_isolated(outputs)
      assert_supervisor_quiescent(supervisor)
      refute_received :action_task_message
    end
  end

  for operation <- [:step, :wave, :continue] do
    test "paused Flow #{operation} uses a fresh Task for each Action" do
      supervisor = start_supervised!(Task.Supervisor)
      {:ok, execution} = Exec.start(flow(), %{}, %{}, task_supervisor: supervisor)
      execution = finish(execution, unquote(operation))
      assert {:ok, outputs} = Exec.result(execution)
      assert_flow_isolated(outputs)
      assert_supervisor_quiescent(supervisor)
      refute_received :action_task_message
    end
  end

  defp assert_isolated(output) do
    refute output.pid == self()
    assert output.before == nil
    refute output.trapping_before
    assert output.logger_before == nil
    monitor = Process.monitor(output.pid)
    assert_receive {:DOWN, ^monitor, :process, _, :noproc}
  end

  defp assert_flow_isolated(outputs) do
    Enum.each(Map.values(outputs), &assert_isolated/1)
    assert outputs |> Map.values() |> Enum.map(& &1.pid) |> Enum.uniq() |> length() == 3
  end

  defp flow do
    JidoActionTest.FlowBuilder.new!(
      name: "action_task_isolation",
      components: [
        JidoActionTest.FlowComponent.step!(name: "one", action: Probe),
        JidoActionTest.FlowComponent.step!(name: "two", action: Probe),
        JidoActionTest.FlowComponent.step!(name: "three", action: Probe, needs: ["one", "two"])
      ],
      output: %{one: Ref.result("one"), two: Ref.result("two"), three: Ref.result("three")}
    )
  end

  defp finish(execution, operation) do
    if Exec.status(execution) == :running do
      current =
        case apply(Exec, operation, [execution]) do
          {:ok, _work, current} -> current
          {:ok, current} -> current
        end

      finish(current, operation)
    else
      execution
    end
  end
end
