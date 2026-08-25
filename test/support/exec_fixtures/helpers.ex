defmodule JidoActionTest.ExecFixtures do
  @moduledoc false

  import ExUnit.Assertions, only: [assert: 1]

  alias Jido.{Exec, Flow, Instruction}
  alias Jido.Flow.Map, as: FlowMap
  alias Jido.Flow.{Node, Reduce, Ref}
  alias JidoActionTest.ExecFixtures.ConcurrencyProbeAction

  alias JidoActionTest.TestActions.{
    Add,
    EchoParamsAction,
    MapProbeAction,
    Multiply,
    ReduceProbeAction
  }

  defmodule BlockingAction do
    @moduledoc false
    use Jido.Action, name: "blocking_action"

    def run(params, %{test_pid: test_pid}) do
      send(test_pid, {:blocking_flow_node_started, self()})

      receive do
        :finish -> {:ok, params}
      end
    end
  end

  defmodule CountedStepFlow do
    @moduledoc false
    use Jido.Flow,
      name: "counted_step_flow",
      schema:
        Zoi.map()
        |> Zoi.transform({JidoActionTest.ExecFixtures, :count_transform, [:input]}),
      output_schema:
        Zoi.map()
        |> Zoi.transform({JidoActionTest.ExecFixtures, :count_transform, [:output]})

    flow do
      step("echo",
        action: JidoActionTest.TestActions.EchoParamsAction,
        params: %{value: input(:value)}
      )
    end
  end

  defmodule NestedStepFlow do
    @moduledoc false
    use Jido.Flow, name: "nested_step_flow"

    flow do
      step("add",
        action: JidoActionTest.TestActions.Add,
        params: %{value: input(:value), amount: 1}
      )
    end
  end

  def count_transform(value, phase, _opts) do
    key = {__MODULE__, phase}
    Process.put(key, Process.get(key, 0) + 1)
    {:ok, value}
  end

  def transform_count(phase), do: Process.get({__MODULE__, phase}, 0)

  def reset_transform_counts do
    Process.delete({__MODULE__, :input})
    Process.delete({__MODULE__, :output})
    :ok
  end

  def linear_flow do
    Flow.new!(
      name: "step_linear",
      nodes: [
        Node.new!(
          name: :add,
          action: Add,
          input: %{value: Ref.input(:value), amount: Ref.value(1)}
        ),
        Node.new!(
          name: :multiply,
          action: Multiply,
          input: %{value: Ref.result(:add, :value), amount: Ref.value(2)}
        )
      ],
      return: Ref.result(:multiply)
    )
  end

  def map_flow(items, on_error) do
    items = Enum.map(items, &Map.put_new(&1, :block, false))

    Flow.new!(
      name: "step_map",
      nodes: [
        FlowMap.new!(
          name: :mapped,
          collection: Ref.value(items),
          action: MapProbeAction,
          input: map_probe_input(),
          on_error: on_error
        )
      ],
      return: Ref.result(:mapped)
    )
  end

  def map_reduce_flow(mode) do
    items =
      case mode do
        :success ->
          [%{value: :zero, outcome: :ok}, %{value: :one, outcome: :ok}]

        :with_error ->
          [%{value: :zero, outcome: :ok}, %{value: :one, outcome: {:error, "failed"}}]
      end
      |> Enum.map(&Map.put_new(&1, :block, false))

    Flow.new!(
      name: "stepwise_map_reduce",
      nodes: [
        FlowMap.new!(
          name: :mapped,
          collection: Ref.value(items),
          action: MapProbeAction,
          input: map_probe_input(),
          on_error: :collect_errors
        ),
        Reduce.new!(
          name: :reduced,
          collection: Ref.result(:mapped),
          initial: Ref.value(%{values: [], indexes: []}),
          action: ReduceProbeAction,
          input: %{
            accumulator: Ref.accumulator(),
            item: Ref.item(:value),
            index: Ref.item_index(),
            item_id: Ref.item_id()
          }
        )
      ],
      return: Ref.result(:reduced)
    )
  end

  def map_probe_input do
    %{
      test_pid: Ref.context(:test_pid),
      index: Ref.item_index(),
      value: Ref.item(:value),
      outcome: Ref.item(:outcome),
      block: Ref.item(:block)
    }
  end

  def diamond_flow(action) do
    branch_input = fn side ->
      %{side: Ref.value(side)}
    end

    Flow.new!(
      name: "step_diamond",
      nodes: [
        Node.new!(name: :right, action: action, input: branch_input.(:right)),
        Node.new!(name: :left, action: action, input: branch_input.(:left)),
        Node.new!(
          name: :merge,
          action: EchoParamsAction,
          input: %{
            left: Ref.result(:left, :side),
            right: Ref.result(:right, :side)
          }
        )
      ],
      return: Ref.result(:merge)
    )
  end

  def probe_diamond_flow do
    branch_input = fn side ->
      %{
        probe: Ref.context(:probe),
        side: Ref.value(side),
        test_pid: Ref.context(:test_pid)
      }
    end

    Flow.new!(
      name: "step_probe_diamond",
      nodes: [
        Node.new!(name: :right, action: ConcurrencyProbeAction, input: branch_input.(:right)),
        Node.new!(name: :left, action: ConcurrencyProbeAction, input: branch_input.(:left)),
        Node.new!(
          name: :merge,
          action: EchoParamsAction,
          input: %{
            left: Ref.result(:left, :side),
            right: Ref.result(:right, :side)
          }
        )
      ],
      return: Ref.result(:merge)
    )
  end

  def wide_flow(node_count) do
    names = Enum.map(1..node_count, &node_name/1)

    nodes =
      names
      |> Enum.reverse()
      |> Enum.map(fn name ->
        Node.new!(name: name, action: EchoParamsAction, input: %{name: Ref.value(name)})
      end)

    return = Map.new(names, &{&1, Ref.result(&1)})
    Flow.new!(name: "wide_step_flow", nodes: nodes, return: return)
  end

  def serial_flow(node_count) do
    nodes =
      Enum.map(1..node_count, fn index ->
        input =
          if index == 1 do
            %{value: Ref.value(0), amount: Ref.value(1)}
          else
            %{value: Ref.result(node_name(index - 1), :value), amount: Ref.value(1)}
          end

        Node.new!(name: node_name(index), action: Add, input: input)
      end)

    Flow.new!(
      name: "serial_step_flow_#{node_count}",
      nodes: nodes,
      return: Ref.result(node_name(node_count))
    )
  end

  def flow_execution_paths(module, input) do
    flow = module.flow()
    instruction = Instruction.new!(action: module, params: input)

    parent =
      Flow.new!(
        name: "parent_#{System.unique_integer([:positive])}",
        nodes: [Node.new!(name: :inner, action: module, input: Ref.input([]))],
        return: Ref.result(:inner)
      )

    [
      artifact: fn -> Exec.run(flow, input, %{}) end,
      module: fn -> Exec.run(module, input, %{}) end,
      instruction: fn -> Exec.run(instruction, %{}, %{}) end,
      parent: fn -> Exec.run(parent, input, %{}) end
    ]
  end

  def assert_ready_cache(execution, expected) do
    assert Exec.ready(execution) == expected
    assert Map.fetch!(execution, :ready_nodes) == expected
    assert execution.ready |> Map.keys() |> Enum.sort() == expected
  end

  def node_name(index) do
    "node_#{index |> Integer.to_string() |> String.pad_leading(4, "0")}"
  end
end
