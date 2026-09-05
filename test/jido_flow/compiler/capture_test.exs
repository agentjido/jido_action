defmodule JidoActionTest.Flow.Compiler.CaptureTest do
  use ExUnit.Case, async: true

  alias Jido.Flow
  alias Jido.Flow.{Ref, Step}
  alias JidoActionTest.Fixtures.FlowAuthoring
  alias JidoActionTest.Fixtures.Actions.EchoParamsAction

  test "compiler callbacks do not retain the compiler state" do
    assert {:ok, compiled} = Flow.compile(FlowAuthoring.mixed_flow!())

    retained =
      compiled.workflow.graph.vertices
      |> Map.values()
      |> Enum.filter(&retains_compiler_state?/1)
      |> Enum.map(& &1.name)

    # Includes Step, Choice, Iterate, Subflow output, Map item, and Reduce.
    assert retained == []
  end

  test "independent Steps have bounded size after transfer to another process" do
    measurements =
      for count <- [1, 2, 4, 6] do
        steps =
          for index <- 1..count do
            Step.new!(name: "s#{index}", action: EchoParamsAction, params: %{value: index})
          end

        flow = Flow.new!(name: "capture_size", components: steps, output: Ref.result("s#{count}"))
        assert {:ok, compiled} = Flow.compile(flow)
        local_words = :erts_debug.flat_size(compiled)
        {copied_words, memory} = transfer_size(compiled)
        assert copied_words == local_words
        {count, local_words, memory}
      end

    {2, small_words, small_memory} = Enum.find(measurements, &(elem(&1, 0) == 2))
    {6, large_words, large_memory} = List.last(measurements)

    # Allow graph overhead and different heap sizes across supported runtimes.
    # Tripling this graph must not multiply its copied size exponentially.
    assert large_words < small_words * 4
    assert large_memory < small_memory * 6
  end

  defp transfer_size(value) do
    owner = self()
    ref = make_ref()

    {receiver, monitor} =
      spawn_monitor(fn ->
        receive do
          {^ref, copied} ->
            {:memory, memory} = Process.info(self(), :memory)
            send(owner, {ref, :erts_debug.flat_size(copied), memory})
        end
      end)

    try do
      send(receiver, {ref, value})
      assert_receive {^ref, words, memory}, 5_000
      assert_receive {:DOWN, ^monitor, :process, ^receiver, :normal}, 5_000
      {words, memory}
    after
      Process.exit(receiver, :kill)
      Process.demonitor(monitor, [:flush])
    end
  end

  defp retains_compiler_state?(%{workflow: _, namespace: _, outputs: _}), do: true

  defp retains_compiler_state?(fun) when is_function(fun) do
    {:env, environment} = :erlang.fun_info(fun, :env)
    retains_compiler_state?(environment)
  end

  defp retains_compiler_state?(map) when is_map(map),
    do: map |> Map.to_list() |> retains_compiler_state?()

  defp retains_compiler_state?(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> retains_compiler_state?()

  defp retains_compiler_state?(list) when is_list(list),
    do: Enum.any?(list, &retains_compiler_state?/1)

  defp retains_compiler_state?(_value), do: false
end
