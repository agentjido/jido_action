defmodule JidoActionTest.Flow.Compiler.NativeRunicTest do
  use ExUnit.Case, async: true

  alias Jido.Flow
  alias Jido.Flow.{Map, Reduce, Ref, Step, Subflow}
  alias JidoActionTest.Fixtures.{MathFlow, TelemetryParentFlow}
  alias JidoActionTest.Fixtures.Actions.{EchoParamsAction, ReduceProbeAction}
  alias Runic.Workflow
  alias Runic.Workflow.{ComponentAdded, Connection, FanIn, FanOut, InputBinding}
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

  defmodule InvalidSourceMapChild do
    @moduledoc false

    def __jido_executable__, do: Jido.Executable.flow(__MODULE__)
    def flow, do: JidoActionTest.Fixtures.MathFlow.flow()

    def __jido_flow_source_map__ do
      %{[:components, "add_one"] => %{file: "child.ex", line: self()}}
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
    assert %RunicStep{name: "echo"} = step = compiled.component_index["echo"].component
    assert [in: step_input] = Runic.Component.inputs(step)
    assert [out: step_output] = Runic.Component.outputs(step)
    assert step_input[:type] == :any
    assert Keyword.get(step_input, :cardinality, :one) == :one
    assert step_output[:type] == :any
    assert Keyword.get(step_output, :cardinality, :one) == :one
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

    native_reduce = compiled.component_index["reduced"].component
    assert %RunicReduce{fan_in: %FanIn{map: map_name}} = native_reduce

    assert map_name == native_map.name
    assert compiled.component_index["reduced"].direct_map

    assert [items: map_input] = Runic.Component.inputs(native_map)
    assert [out: map_output] = Runic.Component.outputs(native_map)
    assert map_input[:cardinality] == :many
    assert map_output[:cardinality] == :many

    assert [items: reduce_input] = Runic.Component.inputs(native_reduce)
    assert [result: reduce_output] = Runic.Component.outputs(native_reduce)
    assert reduce_input[:cardinality] == :many
    assert Keyword.get(reduce_output, :cardinality, :one) == :one

    assert %FanIn{name: "$reduced/reduce", map: "$mapped/map", mergeable: false} =
             native_reduce.fan_in

    vertices = :maps.values(compiled.workflow.graph.vertices)
    assert Enum.any?(vertices, &match?(%FanOut{name: "$mapped/map"}, &1))
    assert Enum.any?(vertices, &match?(%FanIn{name: "$mapped/map-collector"}, &1))
    assert Enum.any?(vertices, &match?(%FanIn{name: "$reduced/reduce"}, &1))
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

    assert %Workflow{} = child = compiled.component_index["math"].component
    assert child.input_ports == [in: [type: :any]]
    assert child.output_ports == [out: [type: :any, from: "math/$output"]]

    assert [in: [type: :any]] = Runic.Component.inputs(child)
    assert [out: [type: :any, from: "math/$output"]] = Runic.Component.outputs(child)

    assert %ComponentAdded{
             name: "math",
             connections: [
               %Connection{
                 source: "$math/subflow",
                 source_port: :out,
                 target: "math",
                 target_port: :in,
                 selector: [],
                 target_path: []
               }
             ]
           } = Enum.find(compiled.workflow.build_log, &(&1.name == "math"))

    assert [%InputBinding{bindings: [binding], input_ports: [in: _input]}] =
             compiled.workflow.graph.vertices
             |> :maps.values()
             |> Enum.filter(&match?(%InputBinding{}, &1))

    assert binding.source_port == :out
    assert binding.target_port == :in
    assert binding.selector == []
    assert binding.target_path == []

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

  test "rejects malformed compile options and source maps" do
    flow =
      Flow.new!(
        name: "source_map_validation",
        components: [Step.new!(name: "echo", action: EchoParamsAction)],
        output: Ref.result("echo")
      )

    invalid_options = [
      :invalid,
      [{:source_map, %{}}, :not_an_option],
      [unknown: true],
      %{[:components, self()] => %{file: "flow.ex", line: 1}},
      %{[:components, "echo"] => %{file: <<255>>, line: 1}},
      %{[:components, "echo"] => %{file: "flow.ex", line: 0}},
      %{[:components, "echo"] => %{file: "flow.ex", line: 1, extra: true}},
      %{[:components, "echo"] => self()}
    ]

    for opts <- invalid_options do
      assert {:error, %Jido.Flow.Error.InvalidDefinitionError{}} = Flow.compile(flow, opts)
    end

    nested =
      Flow.new!(
        name: "invalid_child_source_map",
        components: [Subflow.new!(name: "child", flow: InvalidSourceMapChild)],
        output: Ref.result("child")
      )

    assert {:error,
            %Jido.Flow.Error.InvalidDefinitionError{details: %{flow: InvalidSourceMapChild}}} =
             Flow.compile(nested)
  end

  test "rejects invalid public compilation input" do
    assert {:error, error} = Flow.compile(:not_a_flow)
    assert Exception.message(error) == "expected a Jido.Flow artifact"
  end

  test "locks the native contract to the tested Runic release" do
    assert Application.spec(:runic, :vsn) |> to_string() == "0.1.0-alpha.9"
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
