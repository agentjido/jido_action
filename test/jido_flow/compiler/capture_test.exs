defmodule JidoActionTest.Flow.Compiler.CaptureTest do
  use ExUnit.Case, async: true

  alias Jido.Flow
  alias Jido.Flow.{Ref, Step, Subflow}
  alias JidoActionTest.Fixtures.{FlowAuthoring, TelemetryParentFlow}
  alias JidoActionTest.Fixtures.Actions.EchoParamsAction

  test "compiled Steps do not copy author metadata into callbacks" do
    sizes =
      for meta <- [%{}, %{notes: Enum.to_list(1..5_000)}] do
        flow =
          Flow.new!(
            name: "step_metadata",
            components: [Step.new!(name: "echo", action: EchoParamsAction, meta: meta)],
            output: Ref.result("echo")
          )

        assert {:ok, compiled} = Flow.compile(flow)
        :erts_debug.flat_size(compiled)
      end

    assert Enum.uniq(sizes) |> length() == 1
  end

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

  for shape <- [:independent, :chained, :nested, :map, :reduce] do
    test "#{shape} graphs have bounded size after transfer to another process" do
      measurements =
        for count <- [1, 2, 4, 6] do
          assert {:ok, compiled} = Flow.compile(flow(unquote(shape), count))

          # Stop before copying if a nested capture returns. Collection graphs
          # can otherwise expand much faster than the small Step reproduction.
          refute retains_compiler_state?(compiled)
          local_words = :erts_debug.flat_size(compiled)
          {copied_words, memory} = transfer_size(compiled)
          assert copied_words == local_words
          assert copied_words >= :erts_debug.size(compiled)
          {count, local_words, memory}
        end

      {2, small_words, small_memory} = Enum.find(measurements, &(elem(&1, 0) == 2))
      {6, large_words, large_memory} = List.last(measurements)

      # Allow graph overhead and different heap sizes across supported runtimes.
      # Tripling this graph must not multiply its copied size exponentially.
      assert large_words < small_words * 4
      assert large_memory < small_memory * 6
    end
  end

  defp flow(shape, count) do
    components = Enum.map(1..count, &component(shape, "s#{&1}", &1))
    Flow.new!(name: "capture_size", components: components, output: Ref.result("s#{count}"))
  end

  defp component(:independent, name, index),
    do: Step.new!(name: name, action: EchoParamsAction, params: %{value: index})

  defp component(:chained, name, index) do
    value = if index == 1, do: 7, else: Ref.result("s#{index - 1}", :value)
    Step.new!(name: name, action: EchoParamsAction, params: %{value: value})
  end

  defp component(:nested, name, index),
    do: Subflow.new!(name: name, flow: TelemetryParentFlow, params: %{value: index})

  defp component(:map, name, _index) do
    Jido.Flow.Map.new!(
      name: name,
      collection: [1, 2],
      action: EchoParamsAction,
      params: %{value: Ref.item()}
    )
  end

  defp component(:reduce, name, _index) do
    Jido.Flow.Reduce.new!(
      name: name,
      collection: [1, 2],
      initial: %{},
      action: EchoParamsAction,
      params: %{value: Ref.item()}
    )
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
