defmodule Jido.Exec.RebuildTest do
  use ExUnit.Case, async: true

  alias Jido.Exec
  alias Jido.Exec.Frame
  alias Jido.Flow.Ref
  alias JidoActionTest.Fixtures.Actions.{Add, EchoParamsAction}
  alias Runic.Workflow

  defmodule Sum do
    use Jido.Action, name: "rebuild_sum"

    @impl true
    def run(%{acc: acc, item: item}, _context), do: {:ok, %{total: acc.total + item}}
  end

  defmodule Count do
    use Jido.Action, name: "rebuild_count"

    @impl true
    def run(%{count: count}, _context), do: {:ok, %{count: count + 1}}
  end

  defmodule Child do
    use Jido.Flow, name: "rebuild_child"

    flow do
      step "add", action: Add, params: %{value: input(:value), amount: 10}
      output result("add")
    end
  end

  defmodule Decide do
    use Jido.Action, name: "rebuild_decide"

    @impl true
    def run(params, _context), do: {:ok, params}
  end

  defmodule Expand do
    use Jido.Action, name: "rebuild_expand"

    @impl true
    def run(%{value: value}, _context), do: {:continue, %{value: value}, Child}
  end

  test "every component kind rebuilds from its build log and returns the same result" do
    flow =
      Jido.Flow.new!(%{
        name: "rebuild_all",
        components: [
          %{
            kind: :step,
            name: "step",
            action: Add,
            params: %{value: Ref.input(:value), amount: 1}
          },
          %{
            kind: :choice,
            name: "route",
            options: [
              %{
                name: "big",
                condition: Jido.Expr.new!(:>, [Ref.input(:value), 100]),
                action: Add,
                params: %{value: Ref.input(:value), amount: 100}
              }
            ],
            fallback: %{action: Add, params: %{value: Ref.input(:value), amount: 2}}
          },
          %{
            kind: :map,
            name: "items",
            collection: Ref.input(:items),
            action: EchoParamsAction,
            params: %{item: Ref.item()}
          },
          %{
            kind: :reduce,
            name: "sum",
            collection: Ref.input(:items),
            initial: %{total: 0},
            action: Sum,
            params: %{acc: Ref.accumulator(), item: Ref.item()}
          },
          %{
            kind: :iterate,
            name: "loop",
            action: Count,
            params: %{count: Ref.state(:count)},
            state: %{initial: %{count: 0}, update: %{count: Ref.body_result(:count)}},
            completion: Jido.Expr.new!(:>=, [Ref.state(:count), 3]),
            max_iterations: 5
          },
          %{kind: :subflow, name: "child", flow: Child, params: %{value: Ref.input(:value)}}
        ],
        output: %{
          step: Ref.result("step"),
          route: Ref.result("route"),
          items: Ref.result("items"),
          sum: Ref.result("sum"),
          loop: Ref.result("loop"),
          child: Ref.result("child")
        }
      })

    input = %{value: 5, items: [1, 2, 3]}
    assert {:ok, expected} = Exec.run(flow, input)
    assert rebuilt_output(flow, input) == expected
  end

  test "a Dispatch rebuilds and runs its dynamic Flow target" do
    flow =
      Jido.Flow.new!(%{
        name: "rebuild_dispatch",
        components: [
          %{
            kind: :dispatch,
            name: "next",
            decision: Decide,
            expander: Expand,
            params: %{value: Ref.input(:value)}
          }
        ],
        output: Ref.result("next")
      })

    assert {:ok, %{value: 11} = expected} = Exec.run(flow, %{value: 1})
    assert rebuilt_output(flow, %{value: 1}) == expected
  end

  test "Instructions and Action nodes transmute to Runic workflows" do
    instruction = Jido.Instruction.new!(target: Add, params: %{value: 1, amount: 1})

    assert %Jido.Exec.Node.Action{} = Runic.Transmutable.to_component(instruction)
    assert %Workflow{} = Runic.Transmutable.transmute(instruction)

    node = Runic.Transmutable.to_component(instruction)
    assert ^node = Runic.Transmutable.to_component(node)
    assert %Workflow{} = Runic.Transmutable.transmute(node)

    flow_instruction = Jido.Instruction.new!(target: Child)
    assert %Workflow{} = Runic.Transmutable.to_workflow(flow_instruction)
  end

  defp rebuilt_output(flow, input) do
    rebuilt = flow |> Exec.compile!() |> Workflow.build_log() |> Workflow.from_log()

    workflow =
      rebuilt
      |> Workflow.put_run_context(%{_global: %{}})
      |> Workflow.react_until_satisfied(Workflow.Fact.new(value: Frame.new(input)),
        scheduler_policies: [{:default, %{on_failure: :halt}}]
      )

    # A build log has no output ports, so read the root Flow Output directly.
    {name, _output} =
      Enum.find(Workflow.components(workflow), fn {_name, component} ->
        match?(%Jido.Exec.Node.Output{parent_component: nil}, component)
      end)

    workflow |> Workflow.results([name]) |> Map.fetch!(name)
  end
end
