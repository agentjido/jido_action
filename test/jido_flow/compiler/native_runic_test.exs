defmodule JidoActionTest.Flow.Compiler.NativeRunicTest do
  use ExUnit.Case, async: true

  alias Jido.Flow
  alias Jido.Flow.{Map, Reduce, Ref, Step, Subflow}
  alias JidoActionTest.Fixtures.{MathFlow, TelemetryParentFlow}
  alias JidoActionTest.Fixtures.Actions.{EchoParamsAction, ReduceProbeAction}
  alias Runic.Workflow
  alias Runic.Workflow.{FanIn, FanOut}
  alias Runic.Workflow.Map, as: RunicMap
  alias Runic.Workflow.Reduce, as: RunicReduce
  alias Runic.Workflow.Step, as: RunicStep

  defmodule CycleA do
    @moduledoc false

    def __jido_executable__, do: Jido.Executable.flow(__MODULE__)

    def flow do
      Jido.Flow.new!(
        name: "cycle_a",
        components: [
          Jido.Flow.Subflow.new!(
            name: "b",
            flow: JidoActionTest.Flow.Compiler.NativeRunicTest.CycleB
          )
        ],
        output: Jido.Flow.Ref.result("b")
      )
    end

    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
    def run(params, context), do: Jido.Exec.run(flow(), params, context)
  end

  defmodule CycleB do
    @moduledoc false

    def __jido_executable__, do: Jido.Executable.flow(__MODULE__)

    def flow do
      Jido.Flow.new!(
        name: "cycle_b",
        components: [
          Jido.Flow.Subflow.new!(
            name: "a",
            flow: JidoActionTest.Flow.Compiler.NativeRunicTest.CycleA
          )
        ],
        output: Jido.Flow.Ref.result("a")
      )
    end

    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
    def run(params, context), do: Jido.Exec.run(flow(), params, context)
  end

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

  test "two sibling Subflows have independent native names, hashes, and results" do
    flow =
      Flow.new!(
        name: "sibling_subflows",
        components: [
          Subflow.new!(
            name: "left",
            flow: MathFlow,
            params: %{value: Ref.input(:left)}
          ),
          Subflow.new!(
            name: "right",
            flow: MathFlow,
            params: %{value: Ref.input(:right)}
          )
        ],
        output: %{left: Ref.result("left"), right: Ref.result("right")}
      )

    assert {:ok, compiled} = Flow.compile(flow)

    left = compiled.component_index["left"].children["add_one"].component
    right = compiled.component_index["right"].children["add_one"].component

    assert left.name == "left/add_one"
    assert right.name == "right/add_one"
    refute left.hash == right.hash

    assert Jido.Exec.run(flow, %{left: 1, right: 3}) ==
             {:ok, %{left: %{value: 4}, right: %{value: 8}}}
  end

  test "rejects a recursive Subflow module cycle before compilation" do
    assert {:error, error} = CycleA.flow() |> Flow.compile()
    assert Exception.message(error) =~ "recursive Subflow module cycle"
  end

  test "a child semantic change changes the parent compilation digest" do
    child_module =
      Module.concat(__MODULE__, "VersionedChild#{System.unique_integer([:positive])}")

    define_child_module(child_module, 1)

    on_exit(fn ->
      :code.purge(child_module)
      :code.delete(child_module)
    end)

    flow =
      Flow.new!(
        name: "transitive_digest",
        components: [Subflow.new!(name: "child", flow: child_module)],
        output: Ref.result("child")
      )

    assert {:ok, first} = Flow.compile(flow)

    :code.purge(child_module)
    :code.delete(child_module)
    define_child_module(child_module, 2)
    assert {:ok, second} = Flow.compile(flow)

    refute first.compilation_digest == second.compilation_digest
  end

  test "prefixes source locations through every Subflow level" do
    flow =
      Flow.new!(
        name: "nested_source_map",
        components: [Subflow.new!(name: "outer", flow: TelemetryParentFlow)],
        output: Ref.result("outer")
      )

    assert {:ok, compiled} = Flow.compile(flow)

    assert %{file: parent_file, line: parent_line} =
             compiled.source_map[[:components, "outer", :components, "child"]]

    assert is_binary(parent_file)
    assert is_integer(parent_line)

    assert %{file: child_file, line: child_line} =
             compiled.source_map[
               [:components, "outer", :components, "child", :components, "child_add"]
             ]

    assert is_binary(child_file)
    assert is_integer(child_line)

    refute Elixir.Map.has_key?(
             compiled.source_map,
             [:components, "child", :components, "child_add"]
           )
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

  test "rejects invalid public compilation input" do
    assert {:error, error} = Flow.compile(:not_a_flow)
    assert Exception.message(error) == "expected a Jido.Flow artifact"
  end

  defp define_child_module(module, amount) do
    quoted =
      quote do
        @amount unquote(amount)

        def __jido_executable__, do: Jido.Executable.flow(__MODULE__)

        def flow do
          Jido.Flow.new!(
            name: "versioned_child",
            components: [
              Jido.Flow.Step.new!(
                name: "add",
                action: JidoActionTest.Fixtures.Actions.Add,
                params: %{value: Jido.Flow.Ref.input(:value), amount: @amount}
              )
            ],
            output: Jido.Flow.Ref.result("add")
          )
        end

        def validate_params(params), do: {:ok, params}
        def validate_output(output), do: {:ok, output}
        def run(params, context), do: Jido.Exec.run(flow(), params, context)
      end

    Module.create(module, quoted, Macro.Env.location(__ENV__))
  end
end
