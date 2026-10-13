defmodule Jido.Exec.CompilerTest do
  use ExUnit.Case, async: true

  alias Jido.Exec
  alias Jido.Flow
  alias Jido.Flow.Ref
  alias JidoActionTest.Fixtures.Actions.{Add, EchoParamsAction, FullAction, Multiply}
  alias Runic.Workflow

  defmodule Effect do
    use Jido.Action, name: "compiler_port_effect"

    @impl true
    def run(%{value: value, label: label}, _context), do: {:ok, %{value: value}, [label]}
  end

  defmodule PortChild do
    use Jido.Flow, name: "port_child"

    flow do
      step "sum", action: FullAction, params: %{a: input(:a), b: input(:b)}
      step "tail", action: Effect, params: %{value: 99, label: :child_tail}, needs: ["sum"]
      output result("sum")
    end
  end

  test "a serial Flow compiles to connected Action nodes" do
    flow =
      flow!(
        "serial",
        [
          step("add", Add, %{value: Ref.input(:value), amount: 1}),
          step("multiply", Multiply, %{value: Ref.result("add", :value), amount: 2})
        ],
        Ref.result("multiply")
      )

    assert {:ok, %Runic.Workflow{} = workflow} = Exec.compile(flow)
    assert %Jido.Exec.Node.Action{} = Runic.Workflow.get_component(workflow, "add")
    assert %Jido.Exec.Node.Action{} = Runic.Workflow.get_component(workflow, "multiply")

    assert Exec.run(flow, %{value: 3}) == {:ok, %{value: 8}}
  end

  test "a nested Flow uses a native Runic Workflow boundary" do
    flow =
      flow!(
        "nested",
        [
          %{
            kind: :subflow,
            name: "inner",
            flow: JidoActionTest.Fixtures.NestedFlow,
            params: %{value: Ref.input(:value)}
          },
          step("after", Multiply, %{value: Ref.result("inner", :value), amount: 2})
        ],
        Ref.result("after")
      )

    workflow = Exec.compile!(flow)
    assert %Runic.Workflow{} = Runic.Workflow.get_component(workflow, "inner")

    rebuilt = workflow |> Runic.Workflow.build_log() |> Runic.Workflow.from_log()
    assert %Runic.Workflow{} = Runic.Workflow.get_component(rebuilt, "inner")
    assert Exec.run(flow, %{value: 3}) == {:ok, %{value: 8}}
  end

  test "multiple parents use public ports across nested boundaries and preserve declared output" do
    flow = port_flow()
    workflow = Exec.compile!(flow)

    for name <- ["inner", "after"] do
      assert %Workflow.ComponentAdded{connections: connections, input_mode: :all} =
               Enum.find(Workflow.build_log(workflow), &(&1.name == name))

      assert Enum.map(connections, & &1.target_path) == [[0], [1]]
    end

    expected = {:ok, %{value: 5}, [:left, :right, :child_tail, :after]}

    for concurrency <- [1, 4] do
      assert Exec.run(flow, %{}, %{}, max_concurrency: concurrency) == expected
    end

    rebuilt = workflow |> Workflow.build_log() |> Workflow.from_log()
    {completed, observation} = Workflow.execute(rebuilt, Jido.Exec.Frame.new(%{}))
    assert Exec.result(completed, observation) == expected
  end

  test "public connections report missing source and target ports" do
    workflow = Exec.compile!(Add, name: "source")
    node = Jido.Exec.Node.Action.new(Jido.Instruction.new!(target: Add), name: "target")

    assert_raise ArgumentError, ~r/source.*no output port :missing/, fn ->
      Workflow.add(workflow, node, connections: [[from: {"source", :missing}, to: :in]])
    end

    assert_raise ArgumentError, ~r/target.*no input port :missing/, fn ->
      Workflow.add(workflow, node, connections: [[from: {"source", :out}, to: :missing]])
    end
  end

  test "native grouped Action connections preserve parent order and rebuild" do
    nodes =
      for {name, amount} <- [{"left", 2}, {"right", 4}] do
        Jido.Exec.Node.Action.new(
          Jido.Instruction.new!(target: Add, params: %{amount: amount}),
          name: name
        )
      end

    joined =
      Jido.Exec.Node.Action.new(Jido.Instruction.new!(target: EchoParamsAction), name: "joined")

    definition =
      Enum.reduce(nodes, Workflow.new(), &Workflow.add(&2, &1))
      |> Workflow.add(joined, to: ["right", "left"])

    rebuilt = definition |> Workflow.build_log() |> Workflow.from_log()

    for workflow <- [definition, rebuilt] do
      {completed, observation} = Workflow.execute(workflow, %{value: 1})
      assert Exec.result(completed, observation) == {:ok, %{input: [%{value: 5}, %{value: 3}]}}
    end
  end

  test "managed execution preserves public-port results and effect order" do
    runner = Module.concat(__MODULE__, PortRunner)
    start_supervised!({Runic.Runner, name: runner})
    owner = self()
    id = {:ports, System.unique_integer([:positive])}

    assert {:ok, _worker} =
             Exec.start(runner, id, port_flow(), %{}, %{},
               max_concurrency: 4,
               hooks: [on_idle: fn _state -> send(owner, {:idle, id}) end]
             )

    assert_receive {:idle, ^id}, 2_000
    assert Exec.result(runner, id) == {:ok, %{value: 5}, [:left, :right, :child_tail, :after]}
  end

  defp port_flow do
    Flow.new!(%{
      name: "port_parent",
      components: [
        step("left", Effect, %{value: 2, label: :left}),
        step("right", Effect, %{value: 3, label: :right}),
        %{
          kind: :subflow,
          name: "inner",
          flow: PortChild,
          params: %{a: Ref.result("left", :value), b: Ref.result("right", :value)}
        },
        %{
          kind: :step,
          name: "after",
          action: Effect,
          params: %{value: Ref.result("inner", :result), label: :after},
          needs: ["left"]
        }
      ],
      output: Ref.result("after")
    })
  end

  defp flow!(name, components, output) do
    Flow.new!(%{name: name, components: components, output: output})
  end

  defp step(name, action, params) do
    %{kind: :step, name: name, action: action, params: params}
  end
end
