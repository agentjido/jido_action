defmodule JidoActionTest.Flow.Compiler.NativeRunicTest do
  use ExUnit.Case, async: true

  alias Jido.Flow
  alias Jido.Flow.{Map, Reduce, Ref, Step, Subflow}
  alias JidoActionTest.ExecFixtures.MathFlow
  alias JidoActionTest.TestActions.{EchoParamsAction, ReduceProbeAction}
  alias Runic.Workflow
  alias Runic.Workflow.{FanIn, FanOut}
  alias Runic.Workflow.Map, as: RunicMap
  alias Runic.Workflow.Reduce, as: RunicReduce
  alias Runic.Workflow.Step, as: RunicStep

  test "compiles a Step to a native Runic Step without changing the Flow" do
    flow =
      Flow.new!(
        name: "step_compile",
        components: [
          Step.new!(
            name: "echo",
            action: EchoParamsAction,
            params: %{value: Ref.input([:value])}
          )
        ],
        output: Ref.result("echo")
      )

    before = flow
    assert {:ok, compiled} = Flow.compile(flow)
    assert flow == before
    assert %RunicStep{name: "echo"} = compiled.component_index["echo"].component
    assert %Workflow{} = compiled.workflow
  end

  test "compiles Map and Reduce to native Runic components with direct fan-in" do
    map =
      Map.new!(
        name: "mapped",
        collection: Ref.input([:items]),
        action: EchoParamsAction,
        params: %{value: Ref.item()}
      )

    reduce =
      Reduce.new!(
        name: "reduced",
        collection: Ref.result("mapped"),
        initial: %{values: []},
        action: ReduceProbeAction,
        params: %{
          accumulator: Ref.accumulator(),
          item: Ref.item(),
          index: Ref.item_index(),
          item_id: Ref.item_id()
        }
      )

    flow =
      Flow.new!(
        name: "map_reduce_compile",
        components: [map, reduce],
        output: Ref.result("reduced")
      )

    assert {:ok, compiled} = Flow.compile(flow)

    assert %{component: %RunicMap{} = native_map, collector: %RunicReduce{}} =
             compiled.component_index["mapped"]

    assert %RunicReduce{fan_in: %FanIn{map: map_name}} =
             compiled.component_index["reduced"].component

    assert map_name == native_map.name
    assert compiled.component_index["reduced"].direct_map

    vertices = :maps.values(compiled.workflow.graph.vertices)
    assert Enum.any?(vertices, &match?(%FanOut{}, &1))
    assert Enum.any?(vertices, &match?(%FanIn{}, &1))
    refute Code.ensure_loaded?(Jido.Flow.Compiler.MapResult)
  end

  test "uses one native Workflow boundary for a Subflow" do
    flow =
      Flow.new!(
        name: "subflow_compile",
        components: [
          Subflow.new!(
            name: "math",
            flow: MathFlow,
            params: %{value: Ref.input([:value])}
          )
        ],
        output: Ref.result("math")
      )

    assert {:ok, compiled} = Flow.compile(flow)

    assert %Workflow{input_ports: [_], output_ports: [_]} =
             compiled.component_index["math"].component

    child_names = compiled.component_index["math"].children |> :maps.keys()
    assert child_names == ["add_one", "double"]
  end

  test "source locations do not change compilation identity or Runic hashes" do
    flow =
      Flow.new!(
        name: "source_map_compile",
        components: [Step.new!(name: "echo", action: EchoParamsAction)],
        output: Ref.result("echo")
      )

    source_map = %{[:components, "echo"] => %{file: "flow.ex", line: 12, column: 3}}

    assert {:ok, plain} = Flow.compile(flow)
    assert {:ok, with_source} = Flow.compile(flow, source_map: source_map)
    assert with_source.source_map == source_map
    assert plain.compilation_digest == with_source.compilation_digest

    assert plain.component_index["echo"].component.hash ==
             with_source.component_index["echo"].component.hash
  end
end
