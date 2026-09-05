defmodule JidoActionTest.Exec.TelemetryMeasurementTest do
  use ExUnit.Case, async: false

  alias Jido.Exec.Telemetry
  alias Jido.Exec.Telemetry.Tracker

  for terminal <- [:stop, :error, :fail_all] do
    @tag terminal: terminal
    test "delayed #{terminal} delivery retains lifecycle measurements", %{terminal: terminal} do
      owner = self()
      token = make_ref()
      handler_id = {__MODULE__, token}
      events = for suffix <- [:start, :stop, :error], do: [:jido, :action, suffix]
      :ok = :telemetry.attach_many(handler_id, events, &__MODULE__.handle_event/4, {owner, token})
      on_exit(fn -> :telemetry.detach(handler_id) end)

      {:ok, tracker} = Tracker.start_link()
      on_exit(fn -> Process.exit(tracker, :kill) end)

      held =
        Telemetry.with_tracker(tracker, fn ->
          Telemetry.start([:jido, :action], %{name: :held, execution_id: "measurements"})
        end)

      assert_receive {^token, :event, [:jido, :action, :start], _, %{name: :held}}, 1_000
      assert_receive {^token, :handler_blocked, handler}, 1_000
      on_exit(fn -> Process.exit(handler, :kill) end)
      handler_monitor = Process.monitor(handler)

      queued =
        Telemetry.with_tracker(tracker, fn ->
          Telemetry.start([:jido, :action], %{name: :queued, execution_id: "measurements"})
        end)

      before_close = System.monotonic_time()

      case terminal do
        :stop ->
          :ok = Telemetry.stop(held)
          :ok = Telemetry.stop(queued)

        :error ->
          :ok = Telemetry.error(held, :failed)
          :ok = Telemetry.error(queued, :failed)

        :fail_all ->
          :ok = Tracker.fail_all(tracker, :failed)
      end

      # Each close call is acknowledged while delivery is still blocked.
      # These markers therefore precede delivery of the queued events.
      closed_marker = System.monotonic_time()
      system_marker = System.system_time()
      send(handler, {token, :release})
      assert :ok = Tracker.stop(tracker)
      assert_receive {:DOWN, ^handler_monitor, :process, ^handler, :normal}, 1_000

      assert_receive {^token, :event, [:jido, :action, :start], start_measurements,
                      %{name: :queued}}

      names = if terminal == :fail_all, do: [:queued, :held], else: [:held, :queued]
      suffix = if terminal == :stop, do: :stop, else: :error
      spans = %{held: held, queued: queued}

      for name <- names do
        assert_receive {^token, :event, [:jido, :action, ^suffix], measurements, %{name: ^name}}

        assert measurements.monotonic_time >= before_close
        assert measurements.monotonic_time <= closed_marker
        assert measurements.duration == measurements.monotonic_time - spans[name].started_at
      end

      assert start_measurements.monotonic_time == queued.started_at
      assert start_measurements.system_time <= system_marker
      refute_received {^token, :event, _, _, _}
    end
  end

  test "untracked delivery uses measurements from the lifecycle calls" do
    token = make_ref()
    handler_id = {__MODULE__, token}
    events = [[:jido, :action, :start], [:jido, :action, :stop]]
    :ok = :telemetry.attach_many(handler_id, events, &__MODULE__.handle_event/4, {self(), token})
    on_exit(fn -> :telemetry.detach(handler_id) end)
    before_start = System.system_time()
    span = Telemetry.start([:jido, :action], %{name: :sync, execution_id: "measurements"})
    after_start = System.system_time()
    assert_receive {^token, :event, [:jido, :action, :start], start, _metadata}
    assert start.system_time >= before_start
    assert start.system_time <= after_start
    assert start.monotonic_time == span.started_at

    before_close = System.monotonic_time()
    assert :ok = Telemetry.stop(span)
    after_close = System.monotonic_time()
    assert_receive {^token, :event, [:jido, :action, :stop], stop, _metadata}
    assert stop.monotonic_time >= before_close
    assert stop.monotonic_time <= after_close
    assert stop.duration == stop.monotonic_time - start.monotonic_time
  end

  def handle_event(event, measurements, metadata, {owner, token}) do
    send(owner, {token, :event, event, measurements, metadata})

    if event == [:jido, :action, :start] and metadata.name == :held do
      send(owner, {token, :handler_blocked, self()})

      receive do
        {^token, :release} -> :ok
      end
    end
  end
end
