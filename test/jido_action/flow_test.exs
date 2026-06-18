defmodule JidoTest.FlowTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Flow
  alias Jido.Flow.Step
  alias Jido.Instruction
  alias JidoTest.TestActions.FlowFunctions
  alias JidoTest.TestActions.{Add, Double, NotAnAction}
  alias Runic.Workflow
  alias Runic.Workflow.SchedulerPolicy

  require Runic

  test "builds a flow with action steps and dependencies" do
    flow =
      Flow.new(:math)
      |> Flow.step(:add, Add, params: %{amount: 3})
      |> Flow.step(:double, Double, after: :add)

    assert %Flow{name: :math, flow: entries} = flow

    assert [
             %{
               type: :step,
               name: :add,
               action: Add,
               params: %{amount: 3},
               context: %{},
               after: nil
             },
             %{
               type: :step,
               name: :double,
               action: Double,
               params: %{},
               context: %{},
               after: :add
             }
           ] = entries

    workflow = Flow.to_workflow(flow)

    assert %Workflow{name: :math} = workflow
    assert %{add: %Step{}, double: %Step{}} = Workflow.components(workflow)

    assert %{nodes: nodes, edges: edges} = Flow.graph(flow)
    assert Enum.any?(nodes, &(&1.id == :add))
    assert Enum.any?(edges, &(&1.from == :add and &1.to == :double))
  end

  test "builds single-action flows as IR entries" do
    flow = Flow.from_action(Add, %{amount: 2}, name: :add)

    assert %Flow{
             name: :add,
             flow: [
               %{
                 type: :step,
                 name: :add,
                 action: Add,
                 params: %{amount: 2},
                 context: %{},
                 after: nil
               }
             ],
             policies: []
           } = flow
  end

  test "builds single-action flows from instructions" do
    instruction =
      Instruction.new!(
        action: Add,
        params: %{amount: 1},
        context: %{trace_id: "base"}
      )

    flow =
      Flow.from_action(instruction, %{amount: 3},
        name: :instruction_add,
        context: %{tenant_id: "tenant"}
      )

    assert [
             %{
               type: :step,
               name: :instruction_add,
               action: Add,
               params: %{amount: 3},
               context: %{trace_id: "base", tenant_id: "tenant"},
               after: nil
             }
           ] = flow.flow
  end

  test "builds flows from keyword options and derives single-action names" do
    assert %Flow{name: :keyword, flow: []} = Flow.new(name: :keyword)

    flow = Flow.from_action(Add, amount: 4)

    assert %Flow{
             name: :add,
             flow: [
               %{
                 type: :step,
                 name: :add,
                 action: Add,
                 params: %{amount: 4},
                 context: %{},
                 after: nil
               }
             ]
           } = flow
  end

  test "wraps unnamed Runic workflows" do
    workflow = Workflow.new()

    assert %Flow{
             name: nil,
             flow: [
               %{type: :workflow, name: :workflow, workflow: ^workflow, after: nil}
             ]
           } = Flow.from_workflow(workflow)

    assert_raise ArgumentError, ~r/runtime-only workflow entries/, fn ->
      workflow
      |> Flow.from_workflow()
      |> Flow.to_map()
    end
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

  test "keeps action contract validation at the Runic projection boundary" do
    flow = Flow.new(:bad) |> Flow.step(:bad, NotAnAction)

    assert %Flow{flow: [%{action: NotAnAction}]} = flow

    assert_raise ArgumentError, ~r/not a valid Jido action/, fn ->
      Flow.to_workflow(flow)
    end
  end

  test "validates dependency names" do
    assert %Flow{flow: [%{after: nil}]} =
             Flow.new(%{flow: [%{type: :step, name: :child, action: Add, after: nil}]})

    assert %Flow{flow: [%{after: :parent}]} =
             Flow.new(%{flow: [%{type: :step, name: :child, action: Add, after: :parent}]})

    assert %Flow{flow: [%{after: ["left", :right]}]} =
             Flow.new(%{
               flow: [%{type: :step, name: :child, action: Add, after: ["left", :right]}]
             })

    assert_raise ArgumentError, ~r/cannot be an empty list/, fn ->
      Flow.new(%{flow: [%{type: :step, name: :child, action: Add, after: []}]})
    end

    assert_raise ArgumentError, ~r/must contain only atom or string names/, fn ->
      Flow.new(%{flow: [%{type: :step, name: :child, action: Add, after: [:ok, nil]}]})
    end

    assert_raise ArgumentError, ~r/must be an atom or string/, fn ->
      Flow.new(%{flow: [%{type: :step, name: :child, action: Add, after: 123}]})
    end
  end

  test "rejects malformed flow entries" do
    assert_raise ArgumentError, ~r/Flow.new options must be a keyword list/, fn ->
      Flow.new([:bad])
    end

    assert %Flow{flow: []} = Flow.new(%{flow: nil})

    assert_raise ArgumentError, ~r/invalid type: expected array/, fn ->
      Flow.new(%{flow: :bad})
    end

    assert_raise ArgumentError, ~r/cannot be nil/, fn ->
      Flow.new(%{flow: [%{type: :step, name: :bad, action: nil, after: nil}]})
    end

    assert_raise ArgumentError, ~r/invalid enum value: expected one of/, fn ->
      Flow.new(%{flow: [%{"type" => "unknown", "name" => "bad"}]})
    end

    assert_raise ArgumentError, ~r/invalid enum value: expected one of/, fn ->
      Flow.new(%{flow: [%{type: :unknown, name: :bad}]})
    end

    assert_raise ArgumentError, ~r/must be an external function\/1 capture or MFA tuple/, fn ->
      Flow.new(%{flow: [%{type: :map, name: :bad, after: nil}]})
    end

    assert_raise ArgumentError, ~r/must be an external function\/1 capture or MFA tuple/, fn ->
      Flow.new(%{flow: [%{type: :map, name: :bad, mapper: :not_callable, after: nil}]})
    end

    assert_raise ArgumentError,
                 ~r/must be an external function\/2 capture or MFA tuple/,
                 fn ->
                   Flow.new(%{flow: [%{type: :reduce, name: :bad, after: nil}]})
                 end

    assert_raise ArgumentError,
                 ~r/must be an external function\/2 capture or MFA tuple/,
                 fn ->
                   Flow.new(%{
                     flow: [%{type: :reduce, name: :bad, reducer: :not_callable, after: nil}]
                   })
                 end

    assert_raise ArgumentError,
                 ~r/must be an external function\/2 capture or MFA tuple/,
                 fn ->
                   Flow.new(%{flow: [%{type: :accumulate, name: :bad, after: nil}]})
                 end

    assert_raise ArgumentError,
                 ~r/must be an external function\/2 capture or MFA tuple/,
                 fn ->
                   Flow.new(%{
                     flow: [
                       %{type: :accumulate, name: :bad, reducer: :not_callable, after: nil}
                     ]
                   })
                 end

    assert_raise ArgumentError,
                 ~r/workflow entries must contain a Runic.Workflow/,
                 fn ->
                   Flow.new(%{flow: [%{type: :workflow, name: :bad, workflow: %{}, after: nil}]})
                 end

    assert_raise ArgumentError, ~r/flow entries must be maps/, fn ->
      Flow.new(%{flow: [:bad]})
    end
  end

  test "normalizes string-keyed IR entries for projection inputs" do
    child =
      Workflow.new(:child)
      |> Workflow.add(Step.new(Add, %{amount: 1}, name: :child_add))

    flow =
      Flow.new(%{
        "name" => "projected",
        "flow" => [
          %{
            "type" => "step",
            "name" => "add",
            "action" => Add,
            "params" => %{"amount" => 1},
            "context" => nil
          },
          %{
            "type" => "map",
            "name" => "double_each",
            "mapper" => &FlowFunctions.double/1
          },
          %{
            "type" => "reduce",
            "name" => "sum",
            "init" => 0,
            "reducer" => {:mfa, FlowFunctions, :sum},
            "map" => "double_each",
            "after" => "double_each"
          },
          %{
            "type" => "accumulate",
            "name" => "counter",
            "init" => 0,
            "reducer" => {FlowFunctions, :sum}
          },
          %{
            "type" => "workflow",
            "name" => "child",
            "workflow" => child,
            "after" => "add"
          }
        ]
      })

    assert [
             %{type: :step, name: "add", params: %{"amount" => 1}, context: %{}},
             %{type: :map, name: "double_each", mapper: {FlowFunctions, :double}},
             %{type: :reduce, name: "sum", reducer: {:mfa, FlowFunctions, :sum}},
             %{type: :accumulate, name: "counter", reducer: {FlowFunctions, :sum}},
             %{type: :workflow, name: "child", workflow: ^child}
           ] = flow.flow
  end

  test "returns normalized flow IR as a plain map" do
    flow =
      Flow.new(%{
        "name" => "projected",
        "flow" => [
          %{
            "type" => "map",
            "name" => "double_each",
            "mapper" => &FlowFunctions.double/1
          }
        ],
        "policies" => [{"double_each", %{max_retries: 1}}]
      })

    assert %{
             name: "projected",
             flow: [
               %{
                 type: :map,
                 name: "double_each",
                 mapper: {FlowFunctions, :double},
                 inputs: nil,
                 outputs: nil,
                 after: nil
               }
             ],
             policies: [{"double_each", %{max_retries: 1}}]
           } = Flow.to_map(flow)

    refute is_struct(Flow.to_map(flow), Flow)
  end

  test "adds map primitives as Jido flow entries" do
    flow =
      Flow.new(:map)
      |> Flow.map(:double_each, {FlowFunctions, :double})

    assert [
             %{
               type: :map,
               name: :double_each,
               mapper: {FlowFunctions, :double},
               inputs: nil,
               outputs: nil,
               after: nil
             }
           ] = flow.flow

    workflow =
      flow
      |> Flow.to_workflow()
      |> Workflow.plan_eagerly([1, 2, 3])
      |> Workflow.react_until_satisfied()

    assert Enum.sort(Workflow.raw_productions(workflow)) == [2, 4, 6]
  end

  test "returns node metadata for map primitives" do
    assert %{
             double_each: %{
               type: Runic.Workflow.Map,
               name: :double_each,
               inputs: inputs,
               outputs: outputs
             }
           } =
             Flow.new(:map)
             |> Flow.map(:double_each, {FlowFunctions, :double})
             |> Flow.node_map()

    assert is_list(inputs)
    assert is_list(outputs)
  end

  test "projects map and reduce primitives through Runic fan-out and fan-in" do
    flow =
      Flow.new(:map_reduce)
      |> Flow.map(:double_each, {FlowFunctions, :double})
      |> Flow.reduce(:sum, 0, {FlowFunctions, :sum},
        after: :double_each,
        map: :double_each
      )

    assert [
             %{type: :map, name: :double_each, mapper: {FlowFunctions, :double}, after: nil},
             %{
               type: :reduce,
               name: :sum,
               init: 0,
               reducer: {FlowFunctions, :sum},
               map: :double_each,
               after: :double_each
             }
           ] = flow.flow

    workflow =
      flow
      |> Flow.to_workflow()
      |> Workflow.plan_eagerly([1, 2, 3])
      |> Workflow.react_until_satisfied()

    assert 12 in Workflow.raw_productions(workflow, :sum)
  end

  test "projects reduce primitives over enumerable input without map fan-in" do
    workflow =
      Flow.new(:reduce_only)
      |> Flow.reduce(:sum, 0, {FlowFunctions, :sum})
      |> Flow.to_workflow()
      |> Workflow.plan_eagerly([1, 2, 3])
      |> Workflow.react_until_satisfied()

    assert Workflow.raw_productions(workflow, :sum) == [6]
  end

  test "adds accumulator primitives as stateful flow entries" do
    flow =
      Flow.new(:stateful)
      |> Flow.accumulate(:counter, 0, {FlowFunctions, :sum})

    assert [
             %{
               type: :accumulate,
               name: :counter,
               init: 0,
               reducer: {FlowFunctions, :sum},
               inputs: nil,
               outputs: nil,
               after: nil
             }
           ] = flow.flow

    workflow =
      flow
      |> Flow.to_workflow()
      |> Workflow.plan_eagerly(2)
      |> Workflow.react_until_satisfied()

    assert 2 in Workflow.raw_productions(workflow, :counter)
  end

  test "projects MFA reducers through accumulator primitives" do
    workflow =
      Flow.new(:stateful)
      |> Flow.accumulate(:counter, 0, {:mfa, FlowFunctions, :sum})
      |> Flow.to_workflow()
      |> Workflow.plan_eagerly(3)
      |> Workflow.react_until_satisfied()

    assert 3 in Workflow.raw_productions(workflow, :counter)
  end

  test "validates primitive names and options" do
    assert [
             %{type: :map, mapper: {FlowFunctions, :identity}}
           ] =
             Flow.new(:capture)
             |> Flow.map(:identity, &FlowFunctions.identity/1)
             |> Map.fetch!(:flow)

    assert_raise ArgumentError, ~r/must be an external function\/1 capture or MFA tuple/, fn ->
      Flow.new(:bad)
      |> Flow.map(:anonymous, fn value -> value end)
    end

    assert_raise ArgumentError, ~r/must reference an existing function\/1/, fn ->
      Flow.new(:bad)
      |> Flow.map(:missing, {FlowFunctions, :missing})
    end

    assert_raise ArgumentError, ~r/Flow.map options must not include :name/, fn ->
      Flow.new(:bad)
      |> Flow.map(:expected, {FlowFunctions, :identity}, name: :actual)
    end

    assert_raise ArgumentError,
                 ~r/unknown Flow.reduce options: \[:unknown\]/,
                 fn ->
                   Flow.new(:bad)
                   |> Flow.reduce(:sum, 0, {FlowFunctions, :sum}, unknown: true)
                 end

    assert_raise ArgumentError, ~r/Flow.map options must be a keyword list/, fn ->
      apply(Flow, :map, [Flow.new(:bad), :expected, {FlowFunctions, :identity}, :invalid])
    end

    assert_raise ArgumentError, ~r/Flow.accumulate options must be a keyword list/, fn ->
      Flow.new(:bad)
      |> Flow.accumulate(:counter, 0, {FlowFunctions, :sum}, [:not, :keyword])
    end
  end

  test "rejects reduce entries that reference unknown map components" do
    flow =
      Flow.new(:bad_reduce)
      |> Flow.reduce(:sum, 0, {FlowFunctions, :sum}, map: :missing_map)

    assert_raise ArgumentError, ~r/references unknown map :missing_map/, fn ->
      Flow.to_workflow(flow)
    end
  end

  test "allows reduce entries to target map components in a wrapped workflow" do
    map = Runic.map(fn value -> value * 2 end, name: :raw_map)

    workflow =
      Workflow.new(:raw_map_reduce)
      |> Workflow.add(map)
      |> Flow.from_workflow()
      |> Flow.reduce(:sum, 0, {FlowFunctions, :sum}, after: :raw_map, map: :raw_map)
      |> Flow.to_workflow()
      |> Workflow.plan_eagerly([1, 2, 3])
      |> Workflow.react_until_satisfied()

    assert 12 in Workflow.raw_productions(workflow, :sum)
  end

  test "rejects invalid step options and input shapes" do
    assert_raise ArgumentError, ~r/unknown flow step options/, fn ->
      Flow.new(:bad)
      |> Flow.step(:add, Add, retry: true)
    end

    assert_raise ArgumentError, ~r/Flow.step options must be a keyword list/, fn ->
      apply(Flow, :step, [Flow.new(:bad), :add, Add, :invalid])
    end

    assert_raise ArgumentError, ~r/Flow.from_action options must be a keyword list/, fn ->
      apply(Flow, :from_action, [Add, %{}, :invalid])
    end

    assert_raise ArgumentError, ~r/expected params to be a map or keyword list/, fn ->
      Flow.from_action(Add, 123)
    end

    assert_raise ArgumentError, ~r/expected a map or keyword list/, fn ->
      Flow.from_action(Add, [:not, :keyword])
    end

    assert_raise ArgumentError, ~r/expected an action module or %Jido.Instruction{}/, fn ->
      Flow.from_action(nil)
    end
  end

  test "projects nested workflow entries after preceding entries" do
    child =
      Workflow.new(:child)
      |> Workflow.add(Step.new(Add, %{amount: 1}, name: :child_add))

    flow =
      Flow.new(%{
        name: :parent,
        flow: [
          %{
            type: :step,
            name: :first,
            action: Add,
            params: %{amount: 2},
            context: %{},
            after: nil
          },
          %{type: :workflow, name: :child, workflow: child, after: :first}
        ]
      })

    workflow = Flow.to_workflow(flow)

    assert %{first: %Step{}, child_add: %Step{}} = Workflow.components(workflow)

    assert Enum.any?(Flow.graph(flow).edges, fn edge ->
             edge.from == :first and edge.to == :child_add
           end)
  end

  test "graphs fan-in dependencies with their Runic join node" do
    graph =
      Flow.new(:fan_in)
      |> Flow.step(:a, Add, params: %{amount: 1})
      |> Flow.step(:b, Add, params: %{amount: 2})
      |> Flow.step(:sum, JidoTest.TestActions.SumJoined, after: [:a, :b])
      |> Flow.graph()

    join_node = Enum.find(graph.nodes, &(&1.type == :runic_internal and is_integer(&1.id)))

    assert join_node
    assert Enum.any?(graph.edges, &(&1.from == :a and &1.to == join_node.id))
    assert Enum.any?(graph.edges, &(&1.from == :b and &1.to == join_node.id))
    assert Enum.any?(graph.edges, &(&1.from == join_node.id and &1.to == :sum))
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
    invalid_flow = %Flow{name: "", flow: [], policies: []}

    assert {:ok, ^flow} = Flow.validate(flow)
    assert {:error, {:invalid_flow, ^workflow}} = Flow.validate(workflow)
    assert {:error, {:invalid_flow, :nope}} = Flow.validate(:nope)
    assert {:error, %ArgumentError{message: message}} = Flow.validate(invalid_flow)
    assert message =~ "invalid flow"
  end

  test "raw Runic workflows only enter Flow through from_workflow" do
    workflow =
      Workflow.new(:raw)
      |> Workflow.add(Step.new(Add, %{amount: 1}, name: :add))

    assert %Flow{flow: [%{type: :workflow, workflow: ^workflow}]} = Flow.from_workflow(workflow)

    assert_raise FunctionClauseError, fn -> apply(Flow, :components, [workflow]) end
    assert_raise FunctionClauseError, fn -> apply(Flow, :node_map, [workflow]) end
    assert_raise FunctionClauseError, fn -> apply(Flow, :graph, [workflow]) end
  end
end
