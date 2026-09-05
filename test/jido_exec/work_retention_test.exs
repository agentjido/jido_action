defmodule JidoActionTest.Exec.WorkRetentionTest do
  use ExUnit.Case, async: true

  alias Jido.{Exec, Flow}
  alias Jido.Flow.{Ref, Step}
  alias JidoActionTest.Fixtures.Actions.EchoParamsAction
  alias JidoActionTest.Fixtures.Actions.ErrorAction

  test "failure records do not duplicate native runnable inputs" do
    flow =
      Flow.new!(
        name: "failure_retention",
        components: [
          Step.new!(name: "fail", action: ErrorAction, params: %{value: Ref.input(:value)})
        ],
        output: Ref.result("fail")
      )

    assert {:ok, execution} = Exec.start(flow, %{value: Enum.to_list(1..10_000)})
    assert {:ok, finished} = Exec.continue(execution)
    assert {:error, error} = Exec.result(finished)
    assert error.message == "Action failed"
    assert :erts_debug.flat_size(finished.runnable_errors) < 1_000
  end

  test "ready and completed descriptors do not copy or retain unrelated execution data" do
    measurements =
      for large? <- [false, true] do
        data =
          if large?,
            do: %{map: Map.new(1..10_000, &{&1, &1}), binary: :binary.copy(<<42>>, 1_000_000)},
            else: %{}

        flow =
          Flow.new!(
            name: "inspection_retention",
            components: [
              Step.new!(name: "first", action: EchoParamsAction, params: %{value: 1}),
              Step.new!(name: "last", action: EchoParamsAction, after: ["first"], meta: data)
            ],
            output: Ref.result("last")
          )

        assert {:ok, execution} = Exec.start(flow, data, data)
        ready = Exec.ready(execution)
        ready_size = transfer(ready)
        assert {:ok, completed, next} = Exec.step(execution)
        completed_size = transfer([completed])
        assert {:ok, finished} = Exec.continue(next)
        assert Exec.result(finished) == {:ok, %{}}
        {ready_size, completed_size}
      end

    [{small_ready, small_completed}, {large_ready, large_completed}] = measurements
    assert small_ready.words == large_ready.words
    assert small_completed.words == large_completed.words

    for result <- [small_ready, small_completed, large_ready, large_completed] do
      assert result.words < 200
      assert result.memory < 100_000
      assert result.binary_bytes < 10_000
    end
  end

  defp transfer(value) do
    owner = self()
    ref = make_ref()

    {receiver, monitor} =
      spawn_monitor(fn ->
        receive do
          {^ref, received} ->
            :erlang.garbage_collect()
            {:memory, memory} = Process.info(self(), :memory)
            {:binary, binaries} = Process.info(self(), :binary)

            send(
              owner,
              {ref,
               %{
                 words: :erts_debug.flat_size(received),
                 memory: memory,
                 binary_bytes: Enum.sum(Enum.map(binaries, &elem(&1, 1)))
               }}
            )

            receive do
              {^ref, :release} -> send(owner, {ref, :released, length(received)})
            end
        end
      end)

    try do
      send(receiver, {ref, value})
      assert_receive {^ref, measurement}, 1_000
      send(receiver, {ref, :release})
      assert_receive {^ref, :released, 1}, 1_000
      assert_receive {:DOWN, ^monitor, :process, ^receiver, :normal}, 1_000
      measurement
    after
      Process.exit(receiver, :kill)
      Process.demonitor(monitor, [:flush])
    end
  end
end
