defmodule JidoActionTest.Exec.TelemetryMeasurementTest do
  use ExUnit.Case, async: false

  alias Jido.Exec.Telemetry

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
