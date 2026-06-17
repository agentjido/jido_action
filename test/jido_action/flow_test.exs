defmodule JidoTest.FlowTest do
  use JidoTest.ActionCase, async: true

  require Runic

  alias Jido.Flow
  alias Jido.Flow.Step
  alias Runic.Workflow

  defmodule Add do
    use Jido.Action,
      name: "flow_add",
      schema: Zoi.object(%{value: Zoi.integer(), amount: Zoi.integer() |> Zoi.default(1)}),
      output_schema: Zoi.object(%{value: Zoi.integer()})

    def run(%{value: value, amount: amount}, _context), do: {:ok, %{value: value + amount}}
  end

  defmodule Double do
    use Jido.Action,
      name: "flow_double",
      schema: Zoi.object(%{value: Zoi.integer()}),
      output_schema: Zoi.object(%{value: Zoi.integer()})

    def run(%{value: value}, _context), do: {:ok, %{value: value * 2}}
  end

  defmodule NotAnAction do
    def run(_params, _context), do: {:ok, %{}}
  end

  test "builds a flow with action steps and dependencies" do
    flow =
      Flow.new(:math)
      |> Flow.step(:add, Add, params: %{amount: 3})
      |> Flow.step(:double, Double, after: :add)

    workflow = Flow.to_workflow(flow)

    assert %Workflow{name: :math} = workflow
    assert %{add: %Step{}, double: %Step{}} = Workflow.components(workflow)

    assert %{nodes: nodes, edges: edges} = Flow.graph(flow)
    assert Enum.any?(nodes, &(&1.id == :add))
    assert Enum.any?(edges, &(&1.from == :add and &1.to == :double))
  end

  test "rejects duplicate component names" do
    flow = Flow.new(:math) |> Flow.step(:add, Add)

    assert_raise ArgumentError, ~r/already contains/, fn ->
      Flow.step(flow, :add, Double)
    end
  end

  test "rejects invalid action modules" do
    assert_raise ArgumentError, ~r/not a valid Jido action/, fn ->
      Flow.new(:bad) |> Flow.step(:bad, NotAnAction)
    end
  end

  test "adds native Runic components through component/4" do
    counter = Runic.accumulator(0, fn value, state -> state + value end, name: :counter)

    flow =
      Flow.new(:stateful)
      |> Flow.component(:counter, counter)

    assert %Runic.Workflow.Accumulator{} =
             Workflow.get_component(Flow.to_workflow(flow), :counter)
  end

  test "names unnamed native Runic components from component/4" do
    counter = %{Runic.accumulator(0, fn value, state -> state + value end) | name: nil}

    flow =
      Flow.new(:stateful)
      |> Flow.component(:counter, counter)

    assert %Runic.Workflow.Accumulator{name: :counter} =
             Workflow.get_component(Flow.to_workflow(flow), :counter)
  end

  test "validates flow input values" do
    flow = Flow.new(:valid)
    workflow = Flow.to_workflow(flow)

    assert {:ok, ^flow} = Flow.validate(flow)
    assert {:ok, %Flow{workflow: ^workflow}} = Flow.validate(workflow)
    assert {:error, {:invalid_flow, :nope}} = Flow.validate(:nope)
  end
end
