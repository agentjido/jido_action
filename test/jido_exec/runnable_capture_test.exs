defmodule JidoActionTest.Exec.RunnableCaptureTest do
  use ExUnit.Case, async: true

  alias Jido.{Exec, Flow}
  alias Jido.Flow.{Ref, Step}
  alias JidoActionTest.Fixtures.Actions.EchoParamsAction

  test "concurrent workers do not copy unrelated Flow data or execution indexes" do
    retained = Enum.to_list(1..100_000)

    flow =
      Flow.new!(
        name: "worker_capture",
        components: [
          Step.new!(name: "a", action: EchoParamsAction, params: %{value: "a"}),
          Step.new!(name: "b", action: EchoParamsAction, params: %{value: "b"}),
          Step.new!(
            name: "later",
            action: EchoParamsAction,
            after: ["a", "b"],
            meta: %{retained: retained}
          )
        ],
        output: %{a: Ref.result("a"), b: Ref.result("b")}
      )

    ref = make_ref()
    handler = {__MODULE__, ref}
    assert {:ok, execution} = Exec.start(flow, %{}, %{}, max_concurrency: 2)

    :ok =
      :telemetry.attach(
        handler,
        [:jido, :flow, :node, :start],
        &__MODULE__.measure_worker/4,
        {self(), ref, execution.id}
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    assert {:ok, runnables, finished} = Exec.wave(execution)
    assert Enum.map(runnables, &hd(&1.component_path)) == ["a", "b"]
    assert {:ok, finished} = Exec.continue(finished)
    assert Exec.result(finished) == {:ok, %{a: %{value: "a"}, b: %{value: "b"}}}

    # One copy of this unrelated metadata would already exceed the bound.
    limit = :erts_debug.flat_size(retained) * :erlang.system_info(:wordsize)

    for name <- ["a", "b"] do
      assert_receive {^ref, ^name, worker, memory}, 1_000
      refute worker == self()
      refute Process.alive?(worker)
      assert memory < limit
    end

    refute_received {^ref, _, _, _}
  end

  @doc false
  def measure_worker(_event, _measurements, metadata, {owner, ref, execution_id}) do
    if metadata.execution_id == execution_id and metadata.node in ["a", "b"] do
      {:memory, memory} = Process.info(self(), :memory)
      send(owner, {ref, metadata.node, self(), memory})
    end
  end
end
