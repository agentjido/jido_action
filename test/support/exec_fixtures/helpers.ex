defmodule JidoActionTest.ExecFixtures do
  @moduledoc false

  alias Jido.{Exec, Flow, Instruction}
  alias Jido.Flow.Map, as: FlowMap
  alias Jido.Flow.{Reduce, Ref, Step, Subflow}
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

      output(result("echo"))
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

      output(result("add"))
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
      components: [
        Step.new!(
          name: :add,
          action: Add,
          params: %{value: Ref.input(:value), amount: 1}
        ),
        Step.new!(
          name: :multiply,
          action: Multiply,
          params: %{value: Ref.result(:add, :value), amount: 2}
        )
      ],
      output: Ref.result(:multiply)
    )
  end

  def map_flow(items, on_error) do
    items = Enum.map(items, &Map.put_new(&1, :block, false))

    Flow.new!(
      name: "step_map",
      components: [
        FlowMap.new!(
          name: :mapped,
          collection: items,
          action: MapProbeAction,
          params: map_probe_input(),
          on_error: on_error
        )
      ],
      output: Ref.result(:mapped)
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
      components: [
        FlowMap.new!(
          name: :mapped,
          collection: items,
          action: MapProbeAction,
          params: map_probe_input(),
          on_error: :collect_errors
        ),
        Reduce.new!(
          name: :reduced,
          collection: Ref.result(:mapped),
          initial: %{values: [], indexes: []},
          action: ReduceProbeAction,
          params: %{
            accumulator: Ref.accumulator(),
            item: Ref.item(:value),
            index: Ref.item_index(),
            item_id: Ref.item_id()
          }
        )
      ],
      output: Ref.result(:reduced)
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
      %{side: side}
    end

    Flow.new!(
      name: "step_diamond",
      components: [
        Step.new!(name: :right, action: action, params: branch_input.(:right)),
        Step.new!(name: :left, action: action, params: branch_input.(:left)),
        Step.new!(
          name: :merge,
          action: EchoParamsAction,
          params: %{
            left: Ref.result(:left, :side),
            right: Ref.result(:right, :side)
          }
        )
      ],
      output: Ref.result(:merge)
    )
  end

  def probe_diamond_flow do
    branch_input = fn side ->
      %{
        probe: Ref.context(:probe),
        side: side,
        test_pid: Ref.context(:test_pid)
      }
    end

    Flow.new!(
      name: "step_probe_diamond",
      components: [
        Step.new!(name: :right, action: ConcurrencyProbeAction, params: branch_input.(:right)),
        Step.new!(name: :left, action: ConcurrencyProbeAction, params: branch_input.(:left)),
        Step.new!(
          name: :merge,
          action: EchoParamsAction,
          params: %{
            left: Ref.result(:left, :side),
            right: Ref.result(:right, :side)
          }
        )
      ],
      output: Ref.result(:merge)
    )
  end

  def wide_flow(node_count) do
    names = Enum.map(1..node_count, &node_name/1)

    components =
      names
      |> Enum.reverse()
      |> Enum.map(fn name ->
        Step.new!(name: name, action: EchoParamsAction, params: %{name: name})
      end)

    output = Map.new(names, &{&1, Ref.result(&1)})
    Flow.new!(name: "wide_step_flow", components: components, output: output)
  end

  def serial_flow(node_count) do
    components =
      Enum.map(1..node_count, fn index ->
        params =
          if index == 1 do
            %{value: 0, amount: 1}
          else
            %{value: Ref.result(node_name(index - 1), :value), amount: 1}
          end

        Step.new!(name: node_name(index), action: Add, params: params)
      end)

    Flow.new!(
      name: "serial_step_flow_#{node_count}",
      components: components,
      output: Ref.result(node_name(node_count))
    )
  end

  def flow_execution_paths(module, input) do
    flow = module.flow()
    instruction = Instruction.new!(action: module, params: input)

    parent =
      Flow.new!(
        name: "parent_#{System.unique_integer([:positive])}",
        components: [Subflow.new!(name: :inner, flow: module, params: Ref.input([]))],
        output: Ref.result(:inner)
      )

    [
      artifact: fn -> Exec.run(flow, input, %{}) end,
      module: fn -> Exec.run(module, input, %{}) end,
      instruction: fn -> Exec.run(instruction, %{}, %{}) end,
      parent: fn -> Exec.run(parent, input, %{}) end
    ]
  end

  def node_name(index) do
    "node_#{index |> Integer.to_string() |> String.pad_leading(4, "0")}"
  end
end
