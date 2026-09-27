defmodule JidoActionTest.Exec.ConcurrentTelemetryTest do
  use ExUnit.Case, async: false
  alias Jido.{Exec, Flow}
  alias Jido.Flow.{Ref, Step}

  defmodule Held do
    use Jido.Action, name: "concurrent_telemetry_held"
    @impl true
    def run(params, %{owner: owner, tag: tag}) do
      send(owner, {tag, :ready, self()})
      receive do: (:release -> {:ok, params})
    end
  end

  for mode <- [:direct, :async] do
    @tag mode: mode
    test "#{mode} closes every started span after a concurrent worker kill", %{mode: mode} do
      tag = make_ref()
      owner = self()
      prefixes = [[:jido, :flow], [:jido, :flow, :node], [:jido, :flow, :target]]
      events = for prefix <- prefixes, suffix <- [:start, :stop, :error], do: prefix ++ [suffix]
      :ok = :telemetry.attach_many(tag, events, &__MODULE__.event/4, {owner, tag})
      on_exit(fn -> :telemetry.detach(tag) end)

      flow =
        Flow.new!(
          name: "crash_spans",
          components: [
            Step.new!(name: "a", action: Held),
            Step.new!(name: "b", action: Held)
          ],
          output: Ref.result("b")
        )

      task =
        Task.async(fn ->
          context = %{owner: owner, tag: tag}

          if mode == :direct,
            do: Exec.run(flow, %{}, context),
            else: Exec.await(Exec.run_async(flow, %{}, context))
        end)

      on_exit(fn -> Process.exit(task.pid, :kill) end)
      assert_receive {^tag, :ready, first}, 1_000
      assert_receive {^tag, :ready, second}, 1_000
      Process.exit(first, :kill)
      send(second, :release)
      assert {:error, _} = Task.await(task)
      events = take_events(tag)

      starts =
        for {event, metadata} <- events,
            List.last(event) == :start,
            do: {Enum.drop(event, -1), metadata}

      terminals =
        for {event, metadata} <- events,
            List.last(event) != :start,
            do: {Enum.drop(event, -1), Map.drop(metadata, [:error, :error_type])}

      assert length(starts) == 5
      assert Enum.frequencies(starts) == Enum.frequencies(terminals)
    end
  end

  def event(event, _, metadata, {owner, tag}), do: send(owner, {tag, :event, event, metadata})

  defp take_events(tag) do
    receive do
      {^tag, :event, event, metadata} -> [{event, metadata} | take_events(tag)]
    after
      0 -> []
    end
  end
end
