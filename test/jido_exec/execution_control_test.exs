defmodule JidoActionTest.Exec.ExecutionControlTest do
  use ExUnit.Case, async: false
  import JidoActionTest.ProcessCleanup

  alias Jido.Exec
  alias Jido.Exec.Telemetry
  alias Jido.Flow
  alias Jido.Flow.{Dispatch, Ref, Step}

  defmodule HeldAction do
    use Jido.Action, name: "execution_control_held"

    @impl true
    def run(params, %{test_pid: owner, token: token}) do
      send(owner, {token, :ready, params.phase, self(), Telemetry.tracker()})

      receive do
        {^token, :finish, result} -> result
      end
    end
  end

  defmodule Decision do
    use Jido.Action, name: "execution_control_decision"

    @impl true
    def run(params, _context), do: {:ok, params}
  end

  setup do
    supervisor = start_supervised!(Task.Supervisor)
    token = make_ref()
    handler_id = {__MODULE__, token}
    prefixes = [[:jido, :action], [:jido, :flow], [:jido, :flow, :node], [:jido, :flow, :target]]
    events = for prefix <- prefixes, suffix <- [:start, :stop, :error], do: prefix ++ [suffix]

    :ok = :telemetry.attach_many(handler_id, events, &__MODULE__.record_event/4, {self(), token})
    on_exit(fn -> :telemetry.detach(handler_id) end)
    %{supervisor: supervisor, token: token, monitors_before: Process.info(self(), :monitors)}
  end

  for order <- [:result_first, :cancel_first] do
    @tag order: order
    test "#{order} selects the first queued terminal message", context do
      %{token: token, order: order} = context
      handle = start_held(HeldAction, context)
      assert_receive {^token, :ready, :first, action, tracker}, 1_000
      worker = managed_worker(handle)
      owned = monitor_owned(handle, action, tracker, worker)
      worker_monitor = Process.monitor(worker)
      error = Jido.Exec.Error.cancelled_error("ordered cancellation", %{retry: false})

      # Hold only the controller. Let real Action and execution results queue
      # before it can choose a terminal branch. The worker DOWN is the barrier.
      :erlang.suspend_process(handle.pid)

      try do
        if order == :cancel_first,
          do: send(handle.pid, {Jido.Exec.Async, handle.ref, {:stop, error}})

        send(action, {token, :finish, {:ok, %{value: 7}}})
        assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :normal}, 1_000

        assert {:messages, messages} = Process.info(handle.pid, :messages)
        assert Enum.any?(messages, &match?({_, ^worker, :result, {:ok, %{value: 7}}}, &1))

        if order == :result_first,
          do: send(handle.pid, {Jido.Exec.Async, handle.ref, {:stop, error}})
      after
        :erlang.resume_process(handle.pid)
      end

      expected = if order == :result_first, do: {:ok, %{value: 7}}, else: {:error, error}
      assert ^expected = Exec.await(handle, 1_000)
      assert_cleanup(context, handle, owned)

      # Work had completed before either terminal branch ran. Cancellation must
      # not emit another terminal event for the closed Action lifecycle.
      assert_lifecycles(token, 1, 0)
    end
  end

  test "messages with another reference cannot finish the call", context do
    %{token: token} = context
    handle = start_held(HeldAction, context)
    assert_receive {^token, :ready, :first, action, tracker}, 1_000
    worker = managed_worker(handle)
    owned = monitor_owned(handle, action, tracker, worker)

    # Suspend the controller so unrelated messages precede the real result.
    :erlang.suspend_process(handle.pid)

    try do
      send(handle.pid, {make_ref(), worker, :result, {:ok, %{wrong: :reference}}})

      send(
        handle.pid,
        {Jido.Exec.Async, make_ref(), {:stop, RuntimeError.exception("wrong ref")}}
      )

      send(action, {token, :finish, {:ok, %{value: 7}}})
      worker_monitor = Process.monitor(worker)
      assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _reason}, 1_000
    after
      :erlang.resume_process(handle.pid)
    end

    assert {:ok, %{value: 7}} = Exec.await(handle, 1_000)
    assert_cleanup(context, handle, owned)
    assert_lifecycles(token, 1, 0)
  end

  for direction <- [:action_to_flow, :flow_to_action],
      terminal <- [:timeout, :cancel, :worker_exit] do
    @tag direction: direction, terminal: terminal
    test "#{direction} preserves control state on #{terminal}", context do
      %{token: token, direction: direction, terminal: terminal} = context
      {initial, target} = transition_targets(direction)
      timeout = if terminal == :timeout, do: 1_000, else: :infinity
      handle = start_held(initial, context, timeout: timeout, max_continuations: 1)
      assert_receive {^token, :ready, :first, first_action, tracker}, 1_000
      first_monitor = Process.monitor(first_action)
      send(first_action, {token, :finish, {:continue, %{phase: :next}, target}})
      assert_receive {^token, :ready, :next, action, ^tracker}, 1_000
      assert_receive {:DOWN, ^first_monitor, :process, ^first_action, :normal}, 1_000
      worker = managed_worker(handle)
      owned = monitor_owned(handle, action, tracker, worker)

      case terminal do
        :cancel ->
          assert :ok = Exec.cancel(handle)

        :timeout ->
          assert {:error, error} = Exec.await(handle, 3_000)

          expected_type =
            if direction == :action_to_flow,
              do: Jido.Flow.Error.TimeoutError,
              else: Jido.Action.Error.TimeoutError

          assert error.__struct__ == expected_type
          assert error.timeout == timeout
          assert error.details.retry == false

          if direction == :action_to_flow,
            do: assert(error.details.flow == "execution_control_target"),
            else: assert(error.details.action == HeldAction)

        :worker_exit ->
          Process.exit(worker, :kill)
          assert {:error, error} = Exec.await(handle, 1_000)

          expected_type =
            if direction == :action_to_flow,
              do: Jido.Flow.Error.InternalError,
              else: Jido.Action.Error.InternalError

          assert error.__struct__ == expected_type
          assert error.details == %{reason: :killed}
      end

      assert_cleanup(context, handle, owned)
      {starts, errors} = if direction == :action_to_flow, do: {4, 3}, else: {3, 1}
      assert_lifecycles(token, starts, errors)
    end
  end

  test "owner death in a continuation closes active lifecycles and owned processes", context do
    %{token: token} = context
    test_pid = self()

    {owner, owner_monitor} =
      spawn_monitor(fn ->
        handle =
          Exec.run_async(HeldAction, %{phase: :first}, %{test_pid: test_pid, token: token},
            task_supervisor: context.supervisor
          )

        send(test_pid, {token, :handle, handle})

        receive do
          {^token, :exit} -> :ok
        end
      end)

    on_exit(fn -> Process.exit(owner, :kill) end)
    assert_receive {^token, :handle, handle}, 1_000
    on_exit(fn -> Process.exit(handle.pid, :kill) end)
    assert_receive {^token, :ready, :first, first_action, tracker}, 1_000
    first_monitor = Process.monitor(first_action)
    send(first_action, {token, :finish, {:continue, %{phase: :next}, held_flow()}})
    assert_receive {^token, :ready, :next, action, ^tracker}, 1_000
    assert_receive {:DOWN, ^first_monitor, :process, ^first_action, :normal}, 1_000
    owned = monitor_owned(handle, action, tracker, managed_worker(handle))
    send(owner, {token, :exit})
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}, 1_000
    assert_cleanup(context, handle, owned)
    events = assert_lifecycles(token, 4, 3)

    for {event, metadata} <- events, List.last(event) == :error do
      assert %Jido.Exec.Error.CancelledError{
               details: %{operation: :owner_exit, owner: ^owner, reason: :normal}
             } = metadata.error
    end
  end

  def record_event(event, _measurements, metadata, {owner, token}) do
    send(owner, {token, :event, event, metadata})
  end

  defp start_held(target, context, opts \\ []) do
    handle =
      Exec.run_async(
        target,
        %{phase: :first},
        %{test_pid: self(), token: context.token},
        Keyword.put(opts, :task_supervisor, context.supervisor)
      )

    on_exit(fn -> Process.exit(handle.pid, :kill) end)
    handle
  end

  defp transition_targets(:action_to_flow), do: {HeldAction, held_flow()}

  defp transition_targets(:flow_to_action) do
    flow =
      Flow.new!(
        name: "execution_control_dispatch",
        components: [
          Dispatch.new!(
            name: "next",
            decision: Decision,
            expander: HeldAction,
            params: Ref.input([])
          )
        ],
        output: Ref.result("next")
      )

    {flow, HeldAction}
  end

  defp held_flow do
    Flow.new!(
      name: "execution_control_target",
      components: [Step.new!(name: "work", action: HeldAction, params: Ref.input([]))],
      output: Ref.result("work")
    )
  end

  defp managed_worker(handle) do
    {:monitors, monitors} = Process.info(handle.pid, :monitors)
    [{:process, worker}] = Enum.reject(monitors, &(&1 == {:process, handle.owner}))
    worker
  end

  defp monitor_owned(handle, action, tracker, worker) do
    %{delivery: delivery, delivery_guard: delivery_guard} = :sys.get_state(tracker)

    for pid <- [handle.pid, action, tracker, worker, delivery, delivery_guard] do
      monitor = Process.monitor(pid)
      assert {:monitored_by, owners} = Process.info(pid, :monitored_by)
      assert self() in owners
      {pid, monitor}
    end
  end

  defp assert_cleanup(context, handle, owned) do
    for {pid, monitor} <- owned do
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 1_000
    end

    assert_supervisor_quiescent(context.supervisor)
    assert Process.info(self(), :monitors) == context.monitors_before
    ref = handle.ref
    pid = handle.pid
    refute_received {:jido_exec_async_result, ^ref, ^pid, _result}
    refute_received {:DOWN, _, :process, _, _}
  end

  defp assert_lifecycles(token, expected_starts, expected_errors) do
    events = take_events(token)
    starts = Enum.filter(events, &(List.last(elem(&1, 0)) == :start))
    terminals = Enum.reject(events, &(List.last(elem(&1, 0)) == :start))
    assert length(starts) == expected_starts
    assert Enum.count(terminals, &(List.last(elem(&1, 0)) == :error)) == expected_errors

    signature = fn {event, metadata} ->
      {Enum.drop(event, -1), Map.drop(metadata, [:error, :error_type])}
    end

    assert Enum.frequencies_by(starts, signature) == Enum.frequencies_by(terminals, signature)

    assert [_id] =
             events |> Enum.map(fn {_event, metadata} -> metadata.execution_id end) |> Enum.uniq()

    events
  end

  defp take_events(token) do
    receive do
      {^token, :event, event, metadata} -> [{event, metadata} | take_events(token)]
    after
      0 -> []
    end
  end
end
