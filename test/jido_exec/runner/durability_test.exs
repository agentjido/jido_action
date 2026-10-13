defmodule Jido.Exec.Runner.DurabilityTest do
  use ExUnit.Case, async: false

  alias Jido.Exec
  alias Jido.Flow
  alias Jido.Flow.Ref

  defmodule CheckpointGate do
    use GenServer

    def start_link(owner), do: GenServer.start_link(__MODULE__, owner, name: __MODULE__)
    def wait(label), do: GenServer.call(__MODULE__, {:wait, label}, :infinity)
    def open, do: GenServer.call(__MODULE__, :open)

    @impl GenServer
    def init(owner), do: {:ok, %{owner: owner, open?: false, waiting: []}}

    @impl GenServer
    def handle_call({:wait, label}, from, %{open?: false} = state) do
      send(state.owner, {:checkpoint_waiting, label})
      {:noreply, %{state | waiting: [from | state.waiting]}}
    end

    def handle_call({:wait, _label}, _from, %{open?: true} = state),
      do: {:reply, :ok, state}

    def handle_call(:open, _from, state) do
      Enum.each(state.waiting, &GenServer.reply(&1, :ok))
      {:reply, :ok, %{state | open?: true, waiting: []}}
    end
  end

  defmodule Recorder do
    use GenServer

    def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)
    def completed(step), do: GenServer.call(__MODULE__, {:completed, step})
    def steps, do: GenServer.call(__MODULE__, :steps)

    @impl GenServer
    def init(steps), do: {:ok, steps}

    @impl GenServer
    def handle_call({:completed, step}, _from, steps) do
      {:reply, :ok, steps ++ [step]}
    end

    def handle_call(:steps, _from, steps), do: {:reply, steps, steps}
  end

  defmodule Gate do
    use GenServer

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid, name: __MODULE__)
    def wait, do: GenServer.call(__MODULE__, :wait, :infinity)
    def open, do: GenServer.call(__MODULE__, :open)

    @impl GenServer
    def init(test_pid), do: {:ok, %{open?: false, test_pid: test_pid, waiting: []}}

    @impl GenServer
    def handle_call(:wait, from, %{open?: false} = state) do
      send(state.test_pid, :step_6_waiting)
      {:noreply, %{state | waiting: [from | state.waiting]}}
    end

    def handle_call(:wait, _from, %{open?: true} = state), do: {:reply, :ok, state}

    def handle_call(:open, _from, state) do
      Enum.each(state.waiting, &GenServer.reply(&1, :ok))
      {:reply, :ok, %{state | open?: true, waiting: []}}
    end
  end

  defmodule DurableStep do
    use Jido.Action,
      name: "durable_step",
      schema: Zoi.object(%{step: Zoi.integer(), value: Zoi.integer()}),
      output_schema: Zoi.object(%{value: Zoi.integer()})

    @impl true
    def run(%{step: 6, value: value}, _context) do
      :ok = Gate.wait()
      :ok = Recorder.completed(6)
      {:ok, %{value: value + 1}}
    end

    def run(%{step: step, value: value}, _context) do
      :ok = Recorder.completed(step)
      {:ok, %{value: value + 1}}
    end
  end

  defmodule DurableMapItem do
    use Jido.Action, name: "durable_map_item"

    @impl true
    def run(%{index: 1} = params, _context) do
      :ok = CheckpointGate.wait({:map, 1})
      complete(params)
    end

    def run(params, _context), do: complete(params)

    defp complete(%{index: index, value: value}) do
      :ok = Recorder.completed({:map, index})
      {:ok, %{index: index, value: value * 2}}
    end
  end

  defmodule DurableIteration do
    use Jido.Action, name: "durable_iteration"

    @impl true
    def run(%{index: 1} = params, _context) do
      :ok = CheckpointGate.wait({:iterate, 1})
      complete(params)
    end

    def run(params, _context), do: complete(params)

    defp complete(%{index: index, count: count}) do
      :ok = Recorder.completed({:iterate, index})
      {:ok, %{count: count + 1}}
    end
  end

  defmodule DurableNestedStep do
    use Jido.Action, name: "durable_nested_step"

    @impl true
    def run(%{step: 2} = params, _context) do
      :ok = CheckpointGate.wait({:nested, 2})
      complete(params)
    end

    def run(params, _context), do: complete(params)

    defp complete(%{step: step, value: value}) do
      :ok = Recorder.completed({:nested, step})
      {:ok, %{value: value + 1}}
    end
  end

  defmodule DurableChildFlow do
    use Jido.Flow, name: "durable_child"

    flow do
      step "first",
        action: DurableNestedStep,
        params: %{step: 1, value: input(:value)}

      step "second",
        action: DurableNestedStep,
        params: %{step: 2, value: result("first", :value)}

      output result("second")
    end
  end

  defmodule DispatchDecision do
    use Jido.Action, name: "durable_dispatch_decision"

    @impl true
    def run(params, _context) do
      :ok = Recorder.completed(:dispatch_decision)
      {:ok, params}
    end
  end

  defmodule DispatchExpand do
    use Jido.Action, name: "durable_dispatch_expand"

    @impl true
    def run(%{value: value, target: target}, _context) do
      :ok = Recorder.completed(:dispatch_expander)
      {:continue, %{value: value}, target}
    end
  end

  defmodule DispatchTargetStep do
    use Jido.Action, name: "durable_dispatch_target_step"

    @impl true
    def run(%{value: value}, _context) do
      :ok = CheckpointGate.wait(:dispatch_target)
      :ok = Recorder.completed(:dispatch_target)
      {:ok, %{value: value + 1}}
    end
  end

  defmodule DispatchTargetFlow do
    use Jido.Flow, name: "durable_dispatch_target_flow"

    flow do
      step "target",
        action: DispatchTargetStep,
        params: %{value: input(:value)}

      output result("target")
    end
  end

  test "Runic restores a ten-step Flow at the sixth Action" do
    start_supervised!(Recorder)
    start_supervised!({Gate, self()})
    start_supervised!({Runic.Runner, name: __MODULE__.Runner})

    flow = ten_step_flow()
    execution_id = {:durable, System.unique_integer([:positive])}
    test_pid = self()

    dispatch_hook = fn runnable, _state ->
      if runnable.node.name == "step_6" do
        send(test_pid, {:step_6_identity, runnable.activation_id, runnable.attempt_id})
      end
    end

    assert {:ok, _worker} =
             Exec.start(
               __MODULE__.Runner,
               execution_id,
               flow,
               %{value: 0},
               %{},
               max_concurrency: 1,
               checkpoint_strategy: :every_cycle,
               hooks: [on_dispatch: dispatch_hook]
             )

    assert_receive :step_6_waiting
    assert_receive {:step_6_identity, activation_id, attempt_id}
    assert Recorder.steps() == Enum.to_list(1..5)

    assert :ok = Runic.Runner.checkpoint(__MODULE__.Runner, execution_id)
    assert :ok = Runic.Runner.stop(__MODULE__.Runner, execution_id, persist: true)

    :ok = Gate.open()

    assert {:ok, _worker} =
             Runic.Runner.resume(__MODULE__.Runner, execution_id,
               max_concurrency: 1,
               hooks: [
                 on_dispatch: dispatch_hook,
                 on_idle: fn _state -> send(test_pid, :resumed_flow_idle) end
               ]
             )

    assert_receive {:step_6_identity, ^activation_id, ^attempt_id}
    assert_receive :resumed_flow_idle, 2_000
    assert Recorder.steps() == Enum.to_list(1..10)

    assert {:ok, %{result: %{value: 10}}} =
             Runic.Runner.get_results(__MODULE__.Runner, execution_id, [])

    assert {:ok, workflow} = Runic.Runner.get_workflow(__MODULE__.Runner, execution_id)
    assert Exec.result(workflow) == {:ok, %{value: 10}}

    {store, store_state} = Runic.Runner.get_store(__MODULE__.Runner)
    assert {:ok, events} = store.stream(execution_id, store_state)

    persisted = Enum.to_list(events)
    refute Enum.any?(persisted, &match?(%Jido.Instruction{}, &1))
    refute inspect(persisted) =~ "__jido_flow__"
  end

  test "Runic restores unfinished Map items without replaying completed items" do
    start_supervised!(Recorder)
    start_supervised!({CheckpointGate, self()})
    runner = __MODULE__.MapRunner
    start_supervised!({Runic.Runner, name: runner})

    flow =
      Flow.new!(%{
        name: "durable_map",
        components: [
          %{
            kind: :map,
            name: "items",
            collection: Ref.input(:items),
            action: DurableMapItem,
            params: %{value: Ref.item(), index: Ref.item_index()}
          }
        ],
        output: %{items: Ref.result("items")}
      })

    execution_id = {:durable_map, System.unique_integer([:positive])}
    start_execution(runner, execution_id, flow, %{items: [2, 3, 4]})

    assert_receive {:checkpoint_waiting, {:map, 1}}, 2_000
    # Dispatch order is not a Map contract; result order is.
    completed_before_stop = Recorder.steps()
    assert {:map, 0} in completed_before_stop
    refute {:map, 1} in completed_before_stop

    stop_and_resume(runner, execution_id)
    :ok = CheckpointGate.open()
    assert_receive {:resumed_flow_idle, ^execution_id}, 2_000

    # Each item completes exactly once across the stop and resume.
    assert Enum.sort(Recorder.steps()) == [{:map, 0}, {:map, 1}, {:map, 2}]

    assert %{
             items: [
               %{index: 0, value: 4},
               %{index: 1, value: 6},
               %{index: 2, value: 8}
             ]
           } in results(runner, execution_id)
  end

  test "Runic restores Iterate state at the next body activation" do
    start_supervised!(Recorder)
    start_supervised!({CheckpointGate, self()})
    runner = __MODULE__.IterateRunner
    start_supervised!({Runic.Runner, name: runner})

    flow =
      Flow.new!(%{
        name: "durable_iterate",
        components: [
          %{
            kind: :iterate,
            name: "counter",
            action: DurableIteration,
            params: %{count: Ref.state(:count), index: Ref.iteration_index()},
            state: %{
              schema: Zoi.object(%{count: Zoi.integer()}),
              initial: %{count: 0},
              update: %{count: Ref.body_result(:count)}
            },
            completion: Jido.Expr.new!(:>=, [Ref.iteration_index(), 3]),
            max_iterations: 3
          }
        ],
        output: Ref.result("counter")
      })

    execution_id = {:durable_iterate, System.unique_integer([:positive])}
    start_execution(runner, execution_id, flow, %{})

    assert_receive {:checkpoint_waiting, {:iterate, 1}}, 2_000
    assert Recorder.steps() == [{:iterate, 0}]

    stop_and_resume(runner, execution_id)
    :ok = CheckpointGate.open()
    assert_receive {:resumed_flow_idle, ^execution_id}, 2_000

    assert Recorder.steps() == [{:iterate, 0}, {:iterate, 1}, {:iterate, 2}]

    assert Enum.any?(results(runner, execution_id), fn
             %{iterations: 3, state: %{count: 3}, output: %{count: 3}} -> true
             _value -> false
           end)
  end

  test "Runic restores progress inside a nested Flow" do
    start_supervised!(Recorder)
    start_supervised!({CheckpointGate, self()})
    runner = __MODULE__.NestedRunner
    start_supervised!({Runic.Runner, name: runner})

    flow =
      Flow.new!(%{
        name: "durable_parent",
        components: [
          %{
            kind: :subflow,
            name: "child",
            flow: DurableChildFlow,
            params: %{value: Ref.input(:value)}
          }
        ],
        output: Ref.result("child")
      })

    execution_id = {:durable_nested, System.unique_integer([:positive])}
    start_execution(runner, execution_id, flow, %{value: 0})

    assert_receive {:checkpoint_waiting, {:nested, 2}}, 2_000
    assert Recorder.steps() == [{:nested, 1}]

    stop_and_resume(runner, execution_id)
    :ok = CheckpointGate.open()
    assert_receive {:resumed_flow_idle, ^execution_id}, 2_000

    assert Recorder.steps() == [{:nested, 1}, {:nested, 2}]
    assert %{value: 2} in results(runner, execution_id)
  end

  test "Runic restores a dynamic Dispatch target without replaying its routing Actions" do
    start_supervised!(Recorder)
    start_supervised!({CheckpointGate, self()})
    runner = __MODULE__.DispatchRunner
    start_supervised!({Runic.Runner, name: runner})

    flow =
      Flow.new!(%{
        name: "durable_dispatch",
        components: [
          %{
            kind: :dispatch,
            name: "route",
            decision: DispatchDecision,
            expander: DispatchExpand,
            params: %{
              value: Ref.input(:value),
              target: DispatchTargetFlow
            }
          }
        ],
        output: Ref.result("route")
      })

    execution_id = {:durable_dispatch, System.unique_integer([:positive])}
    start_execution(runner, execution_id, flow, %{value: 4})

    assert_receive {:checkpoint_waiting, :dispatch_target}, 2_000
    assert Recorder.steps() == [:dispatch_decision, :dispatch_expander]

    assert :ok = Runic.Runner.checkpoint(runner, execution_id)
    assert_dynamic_components_persisted(runner, execution_id)
    assert :ok = Runic.Runner.stop(runner, execution_id, persist: true)

    resume_execution(runner, execution_id)
    :ok = CheckpointGate.open()
    assert_receive {:resumed_flow_idle, ^execution_id}, 2_000

    assert Recorder.steps() == [:dispatch_decision, :dispatch_expander, :dispatch_target]
    assert %{value: 5} in results(runner, execution_id)
  end

  defp ten_step_flow do
    components =
      Enum.map(1..10, fn step ->
        value = if step == 1, do: Ref.input(:value), else: Ref.result("step_#{step - 1}", :value)

        %{
          kind: :step,
          name: "step_#{step}",
          action: DurableStep,
          params: %{step: step, value: value}
        }
      end)

    Flow.new!(%{
      name: "durable_ten_steps",
      components: components,
      output: Ref.result("step_10")
    })
  end

  defp start_execution(runner, execution_id, flow, input) do
    assert {:ok, _worker} =
             Exec.start(runner, execution_id, flow, input, %{},
               max_concurrency: 1,
               checkpoint_strategy: :every_cycle
             )
  end

  defp stop_and_resume(runner, execution_id) do
    assert :ok = Runic.Runner.checkpoint(runner, execution_id)
    assert :ok = Runic.Runner.stop(runner, execution_id, persist: true)
    resume_execution(runner, execution_id)
  end

  defp resume_execution(runner, execution_id) do
    test_pid = self()

    assert {:ok, _worker} =
             Runic.Runner.resume(runner, execution_id,
               max_concurrency: 1,
               hooks: [
                 on_idle: fn _state -> send(test_pid, {:resumed_flow_idle, execution_id}) end
               ]
             )
  end

  defp results(runner, execution_id) do
    assert {:ok, productions} = Runic.Runner.get_results(runner, execution_id)
    productions
  end

  defp assert_dynamic_components_persisted(runner, execution_id) do
    {store, store_state} = Runic.Runner.get_store(runner)
    assert {:ok, events} = store.stream(execution_id, store_state)

    assert Enum.any?(events, fn
             %Runic.Workflow.ComponentAdded{name: name, workflow_definition: definition}
             when is_binary(name) and not is_nil(definition) ->
               String.starts_with?(name, "__jido_dispatch__/")

             _event ->
               false
           end)
  end
end
