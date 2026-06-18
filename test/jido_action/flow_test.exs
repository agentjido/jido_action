defmodule JidoTest.FlowTest do
  use JidoTest.ActionCase, async: true

  require Runic

  alias Jido.Flow
  alias Jido.Flow.Step
  alias Runic.Workflow
  alias Runic.Workflow.SchedulerPolicy

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

  defmodule NamedComponent do
    defstruct [:name, :hash]
  end

  test "builds a flow with action steps and dependencies" do
    flow =
      Flow.new(:math)
      |> Flow.step(:add, Add, params: %{amount: 3})
      |> Flow.step(:double, Double, after: :add)

    assert %Flow{name: :math, flow: entries} = flow

    assert [
             %{type: :step, name: :add, component: %Step{action: Add}, after: nil},
             %{type: :step, name: :double, component: %Step{action: Double}, after: :add}
           ] = entries

    workflow = Flow.to_workflow(flow)

    assert %Workflow{name: :math} = workflow
    assert %{add: %Step{}, double: %Step{}} = Workflow.components(workflow)

    assert %{nodes: nodes, edges: edges} = Flow.graph(flow)
    assert Enum.any?(nodes, &(&1.id == :add))
    assert Enum.any?(edges, &(&1.from == :add and &1.to == :double))
  end

  test "builds single-action flows as IR entries" do
    flow = Flow.single(Add, %{amount: 2}, name: :add)

    assert %Flow{
             name: :add,
             flow: [
               %{
                 type: :step,
                 name: :add,
                 component: %Step{action: Add, params: %{amount: 2}},
                 after: nil
               }
             ],
             policies: []
           } = flow
  end

  test "projects empty flows to empty Runic workflows" do
    assert %Workflow{name: nil, components: components} = Flow.new() |> Flow.to_workflow()
    assert components == %{}
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

  test "validates dependency names" do
    assert :ok = Flow.validate_dependency(nil)
    assert :ok = Flow.validate_dependency(:parent)
    assert :ok = Flow.validate_dependency(["left", :right])

    assert {:error, "cannot be an empty list"} = Flow.validate_dependency([])

    assert {:error, "must contain only atom or string names"} =
             Flow.validate_dependency([:ok, nil])

    assert {:error, "must be an atom or string"} = Flow.validate_dependency(123)
  end

  test "rejects malformed flow entries" do
    assert_raise ArgumentError, ~r/step entries must contain a Jido.Flow.Step component/, fn ->
      Flow.new(%{flow: [%{type: :step, name: :bad, component: %{}, after: nil}]})
    end

    assert_raise ArgumentError, ~r/component entries must contain a struct component/, fn ->
      Flow.new(%{flow: [%{type: :component, name: :bad, component: :not_a_struct, after: nil}]})
    end

    assert_raise ArgumentError,
                 ~r/workflow entries must contain a Runic.Workflow component/,
                 fn ->
                   Flow.new(%{flow: [%{type: :workflow, name: :bad, component: %{}, after: nil}]})
                 end
  end

  test "adds native Runic components through component/4" do
    counter = Runic.accumulator(0, fn value, state -> state + value end, name: :counter)

    flow =
      Flow.new(:stateful)
      |> Flow.component(:counter, counter)

    assert [%{type: :component, name: :counter, component: ^counter, after: nil}] = flow.flow

    assert %Runic.Workflow.Accumulator{} =
             Workflow.get_component(Flow.to_workflow(flow), :counter)
  end

  test "projects native Runic map and reduce primitives" do
    map = Runic.map(fn value -> value * 2 end, name: :double_each)
    reduce = Runic.reduce(0, fn value, acc -> value + acc end, name: :sum, map: :double_each)

    flow =
      Flow.new(:map_reduce)
      |> Flow.component(:double_each, map)
      |> Flow.component(:sum, reduce, after: :double_each)

    workflow =
      flow
      |> Flow.to_workflow()
      |> Workflow.plan_eagerly([1, 2, 3])
      |> Workflow.react_until_satisfied()

    assert 12 in Workflow.raw_productions(workflow, :sum)
  end

  test "keeps scheduler policies as flow data before Runic projection" do
    flow =
      Flow.new(:policy)
      |> Flow.step(:add, Add)
      |> Flow.policy(:add, max_retries: 1, backoff: :none)

    assert flow.policies == [{:add, %{max_retries: 1, backoff: :none}}]
    assert Flow.to_workflow(flow).scheduler_policies == flow.policies
  end

  test "normalizes scheduler policy structs and rejects invalid policy shapes" do
    flow =
      Flow.new(:policy)
      |> Flow.step(:add, Add)
      |> Flow.policy(:add, %SchedulerPolicy{max_retries: 2})

    assert [{:add, policy}] = flow.policies
    assert policy.max_retries == 2
    assert policy.timeout_ms == :infinity

    assert_raise ArgumentError, ~r/expected scheduler policy to be a keyword list/, fn ->
      Flow.policy(flow, :add, [:not_a_keyword])
    end

    assert_raise ArgumentError, ~r/expected scheduler policy to be a map/, fn ->
      Flow.policy(flow, :add, :invalid)
    end
  end

  test "names unnamed native Runic components from component/4" do
    counter = %{Runic.accumulator(0, fn value, state -> state + value end) | name: nil}

    flow =
      Flow.new(:stateful)
      |> Flow.component(:counter, counter)

    assert %Runic.Workflow.Accumulator{name: :counter} =
             Workflow.get_component(Flow.to_workflow(flow), :counter)
  end

  test "rejects native component name mismatches" do
    component = %NamedComponent{name: :actual, hash: 1}

    assert_raise ArgumentError,
                 ~r/component name :actual does not match flow name :expected/,
                 fn ->
                   Flow.new(:bad) |> Flow.component(:expected, component)
                 end
  end

  test "continues from runtime-only workflow entries" do
    base =
      Workflow.new(:continued)
      |> Workflow.add(Step.new(Add, %{amount: 1}, name: :add))

    flow =
      base
      |> Flow.from_workflow()
      |> Flow.step(:double, Double, after: :add)

    assert %{add: %Step{}, double: %Step{}} = flow |> Flow.to_workflow() |> Workflow.components()

    assert_raise ArgumentError, ~r/already contains/, fn ->
      Flow.from_workflow(base) |> Flow.step(:add, Add)
    end
  end

  test "validates flow input values" do
    flow = Flow.new(:valid)
    workflow = Flow.to_workflow(flow)

    assert {:ok, ^flow} = Flow.validate(flow)

    assert {:ok, %Flow{name: :valid, flow: [%{type: :workflow, component: ^workflow}]}} =
             Flow.validate(workflow)

    assert {:error, {:invalid_flow, :nope}} = Flow.validate(:nope)
  end
end
