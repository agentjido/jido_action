defmodule JidoActionTest.Exec.NativeFlowExecutionTest do
  use ExUnit.Case, async: true

  alias Jido.Exec
  alias Jido.Flow
  alias Jido.Flow.{Map, Reduce, Ref, Step, Subflow}
  alias JidoActionTest.Fixtures.{ChoicePublicPaths, MathFlow}
  alias JidoActionTest.Fixtures.ChildIterator

  alias JidoActionTest.Fixtures.Actions.{
    EchoParamsAction,
    ErrorAction,
    RecorderAction,
    ReduceProbeAction
  }

  alias JidoActionTest.Fixtures.Execution, as: ExecFixtures

  alias Runic.Workflow.{FanIn, FanOut, InputBinding, Runnable}

  defmodule ContinueToAdd do
    use Jido.Action,
      name: "flow_continue_to_add",
      schema: Zoi.object(%{value: Zoi.integer()}),
      output_schema: Zoi.object(%{value: Zoi.integer()})

    @impl true
    def run(%{value: value}, _context) do
      {:continue, %{value: value, amount: 2}, JidoActionTest.Fixtures.Actions.Add}
    end
  end

  defmodule ContinueToMathFlow do
    use Jido.Action,
      name: "flow_continue_to_math_flow",
      schema: Zoi.object(%{value: Zoi.integer()}),
      output_schema: Zoi.object(%{value: Zoi.integer()})

    @impl true
    def run(%{value: value}, _context) do
      {:continue, %{value: value}, JidoActionTest.Fixtures.MathFlow}
    end
  end

  defmodule ContinueToInvalidTarget do
    use Jido.Action, name: "flow_continue_to_invalid_target"

    @impl true
    def run(_params, _context), do: {:continue, %{}, :not_an_executable}
  end

  defmodule ContinueToError do
    use Jido.Action, name: "flow_continue_to_error"

    @impl true
    def run(_params, _context) do
      {:continue, %{error_type: :validation}, JidoActionTest.Fixtures.Actions.ErrorAction}
    end
  end

  test "full execution and native-runnable step execution return the same value" do
    assert {:ok, expected} = Exec.run(MathFlow, %{value: 3})
    assert {:ok, execution} = Exec.start(MathFlow, %{value: 3})
    assert [%Runnable{node: %{name: "add_one"}} = first] = Exec.ready(execution)

    assert {:ok, %Runnable{id: id, status: :completed}, execution} =
             Exec.step(execution, first.id)

    assert id == first.id
    assert [%Runnable{node: %{name: "double"}} = second] = Exec.ready(execution)
    assert {:ok, %Runnable{status: :completed}, execution} = Exec.step(execution, second)
    assert Exec.status(execution) == :succeeded
    assert Exec.result(execution) == {:ok, expected}
  end

  test "an Action continuation runs before the authored downstream Step" do
    flow =
      Flow.new!(
        name: "action_continuation_order",
        components: [
          Step.new!(
            name: "continue",
            action: ContinueToAdd,
            params: %{value: Ref.input(:value)}
          ),
          Step.new!(
            name: "downstream",
            action: JidoActionTest.Fixtures.Actions.Multiply,
            params: %{value: Ref.result("continue", :value), amount: 2}
          )
        ],
        output: Ref.result("downstream")
      )

    assert Exec.run(flow, %{value: 3}) == {:ok, %{value: 10}}

    assert {:ok, execution} = Exec.start(flow, %{value: 3})
    assert [%Runnable{node: %{name: "continue"}}] = Exec.ready(execution)

    assert {:ok, %Runnable{result: result}, execution} = Exec.step(execution)
    refute inspect(result) =~ "JidoActionTest.Fixtures.Actions.Add"
    assert [%Runnable{node: %{name: "$continue/1/target"}}] = Exec.ready(execution)

    assert {:ok, execution} = Exec.continue(execution)
    assert Exec.result(execution) == {:ok, %{value: 10}}
  end

  test "a Flow continuation merges into the live workflow before downstream work" do
    flow =
      Flow.new!(
        name: "flow_continuation_order",
        components: [
          Step.new!(
            name: "continue",
            action: ContinueToMathFlow,
            params: %{value: Ref.input(:value)}
          ),
          Step.new!(
            name: "downstream",
            action: JidoActionTest.Fixtures.Actions.Multiply,
            params: %{value: Ref.result("continue", :value), amount: 2}
          )
        ],
        output: Ref.result("downstream")
      )

    assert Exec.run(flow, %{value: 3}) == {:ok, %{value: 16}}

    assert {:ok, execution} = Exec.start(flow, %{value: 3})
    assert {:ok, _runnable, execution} = Exec.step(execution)

    names =
      execution
      |> Exec.workflow()
      |> then(& &1.graph.vertices)
      |> :maps.values()
      |> Enum.flat_map(fn
        %{name: name} when is_binary(name) -> [name]
        _node -> []
      end)

    assert "$continue/1/add_one" in names
    assert "$continue/1/double" in names
    assert "$continue/1/$output" in names

    assert {:ok, execution} = Exec.continue(execution)
    assert Exec.result(execution) == {:ok, %{value: 16}}
  end

  test "continuation attachment and target failures stop normal Steps" do
    for {name, action, options, message} <- [
          {"invalid_target", ContinueToInvalidTarget, [],
           "action returned an invalid continuation target"},
          {"target_error", ContinueToError, [], "Validation error"},
          {"global_limit", ContinueToAdd, [max_continuations: 0], "continuation limit exceeded"}
        ] do
      flow =
        Flow.new!(
          name: name,
          components: [Step.new!(name: "continue", action: action, params: %{value: 1})],
          output: Ref.result("continue")
        )

      assert {:error, error} = Exec.run(flow, %{}, %{}, options)
      assert Exception.message(error) == message
    end
  end

  test "an older execution revision cannot dispatch the same Runnable again" do
    assert {:ok, stale} = Exec.start(MathFlow, %{value: 3})
    assert {:ok, %Runnable{status: :completed}, current} = Exec.step(stale)
    assert current.revision == 1

    assert {:error,
            %Jido.Flow.Error.InvalidExecutionError{
              message: "stale flow execution",
              details: %{reason: :stale_revision, revision: 0, current_revision: 1}
            }} = Exec.step(stale)
  end

  test "one wave consumes one revision and a stale value dispatches no work" do
    flow = ExecFixtures.diamond_flow(RecorderAction)
    assert {:ok, stale} = Exec.start(flow, %{}, %{test_pid: self()})
    assert length(Exec.ready(stale)) == 2

    assert {:ok, executed, current} = Exec.wave(stale)
    assert length(executed) == 2
    assert current.revision == 1

    assert_receive {RecorderAction, %{side: :left}}
    assert_receive {RecorderAction, %{side: :right}}

    assert {:error,
            %Jido.Flow.Error.InvalidExecutionError{
              message: "stale flow execution",
              details: %{reason: :stale_revision, revision: 0, current_revision: 1}
            }} = Exec.wave(stale)

    refute_received {RecorderAction, _params}
    assert {:ok, completed} = Exec.continue(current)
    assert Exec.result(completed) == {:ok, %{left: :left, right: :right}}
  end

  test "ready, step, and wave expose Runic support runnables" do
    flow = map_reduce_flow()
    assert {:ok, execution} = Exec.start(flow, %{items: [1, 2, 3]})
    {seen, execution} = run_waves(execution, [])

    assert Exec.result(execution) ==
             {:ok, %{values: [%{value: 1}, %{value: 2}, %{value: 3}], indexes: [0, 1, 2]}}

    assert FanOut in seen
    assert FanIn in seen
    assert Runic.Workflow.Step in seen
  end

  test "a Subflow exposes its child and native InputBinding runnables" do
    flow =
      Flow.new!(
        name: "native_subflow_execution",
        components: [
          Subflow.new!(
            name: "child",
            flow: MathFlow,
            params: %{value: Ref.input([:value])}
          )
        ],
        output: Ref.result("child")
      )

    assert {:ok, execution} = Exec.start(flow, %{value: 3})
    {runnables, execution} = collect_runnables(execution, [])

    names =
      for %Runnable{node: %{name: name}} <- runnables,
          do: name

    assert "child/$input" in names
    assert "child/add_one" in names
    assert "child/double" in names
    assert "child/$output" in names
    assert Enum.any?(runnables, &match?(%Runnable{node: %InputBinding{}}, &1))
    assert Exec.result(execution) == {:ok, %{value: 8}}
  end

  test "after controls readiness but does not add predecessor values to params" do
    flow =
      Flow.new!(
        name: "after_is_control",
        components: [
          Step.new!(name: "left", action: EchoParamsAction, params: %{side: :left}),
          Step.new!(name: "right", action: EchoParamsAction, params: %{side: :right}),
          Step.new!(
            name: "final",
            action: EchoParamsAction,
            params: %{value: :only_authored_data},
            after: ["left", "right"]
          )
        ],
        output: Ref.result("final")
      )

    assert Exec.run(flow) == {:ok, %{value: :only_authored_data}}

    assert {:ok, execution} = Exec.start(flow)
    {runnables, execution} = collect_runnables(execution, [])
    assert Enum.any?(runnables, &match?(%Runnable{node: %Runic.Workflow.Join{}}, &1))
    assert Exec.result(execution) == {:ok, %{value: :only_authored_data}}
  end

  test "Choice keeps first-match and fallback behavior in one native Step" do
    assert Exec.run(ChoicePublicPaths, %{kind: :priority, value: 2}) == {:ok, %{value: 3}}
    assert Exec.run(ChoicePublicPaths, %{kind: :normal, value: 2}) == {:ok, %{value: 4}}
  end

  test "Iterate stays one bounded native Step" do
    assert {:ok, execution} = Exec.start(ChildIterator, %{start: 0, limit: 3})
    assert [%Runnable{node: %Runic.Workflow.Step{name: "child"}}] = Exec.ready(execution)

    assert {:ok,
            %{
              kind: :jido_flow_iterate_result,
              iterations: 1,
              state: %{count: 1},
              output: %{count: 1}
            }} = Exec.run(ChildIterator, %{start: 0, limit: 3})
  end

  test "Map preserves input order and handles an empty collection" do
    map =
      Map.new!(
        name: "mapped",
        collection: Ref.input([:items]),
        action: EchoParamsAction,
        params: %{value: Ref.item(), index: Ref.item_index()}
      )

    flow =
      Flow.new!(
        name: "map_results",
        components: [map],
        output: %{items: Ref.result("mapped")}
      )

    assert Exec.run(flow, %{items: [:a, :b, :c]}, %{}, max_concurrency: 3) ==
             {:ok,
              %{
                items: [
                  %{value: :a, index: 0},
                  %{value: :b, index: 1},
                  %{value: :c, index: 2}
                ]
              }}

    assert Exec.run(flow, %{items: []}) == {:ok, %{items: []}}
  end

  test "Reduce handles an ordinary list, an empty list, and target failure" do
    reduce =
      Reduce.new!(
        name: "reduced",
        collection: Ref.input(:items),
        initial: %{values: [], indexes: []},
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
        name: "ordinary_reduce",
        components: [reduce],
        output: %{result: Ref.result("reduced")}
      )

    assert Exec.run(flow, %{items: [:a, :b]}) ==
             {:ok, %{result: %{values: [:a, :b], indexes: [0, 1]}}}

    assert Exec.run(flow, %{items: []}) ==
             {:ok, %{result: %{values: [], indexes: []}}}

    failed = %{
      reduce
      | action: ErrorAction,
        params: %{error_type: :validation}
    }

    failed_flow = %{flow | name: "ordinary_reduce_failure", components: [failed]}

    assert {:error, %Jido.Action.Error.ExecutionFailureError{}} =
             Exec.run(failed_flow, %{items: [1]})
  end

  test "Map error modes use failure or portable tagged outcomes" do
    fail_fast =
      Map.new!(
        name: "mapped",
        collection: [1],
        action: ErrorAction,
        params: %{error_type: :validation},
        on_error: :fail_fast
      )

    collect = %{fail_fast | on_error: :collect_errors}

    fail_flow =
      Flow.new!(name: "map_fail", components: [fail_fast], output: %{items: Ref.result("mapped")})

    collect_flow =
      Flow.new!(
        name: "map_collect",
        components: [collect],
        output: %{items: Ref.result("mapped")}
      )

    assert {:error, %Jido.Action.Error.ExecutionFailureError{}} = Exec.run(fail_flow)

    assert {:ok, %{items: [%{status: :error, error: %{message: "Validation error"}}]}} =
             Exec.run(collect_flow)
  end

  test "the DSL module supplies canonical Flow data and compiled Runic data" do
    assert %Flow{} = MathFlow.flow()
    assert %Jido.Flow.Compiled{workflow: %Runic.Workflow{}} = MathFlow.compiled()
    assert MathFlow.run(%{value: 5}, %{}) == {:ok, %{value: 12}}
  end

  defp map_reduce_flow do
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

    Flow.new!(
      name: "native_map_reduce_execution",
      components: [map, reduce],
      output: Ref.result("reduced")
    )
  end

  defp run_waves(execution, seen) do
    if Exec.status(execution) == :running do
      ready = Exec.ready(execution)
      seen = seen ++ Enum.map(ready, & &1.node.__struct__)
      assert {:ok, _executed, execution} = Exec.wave(execution)
      run_waves(execution, seen)
    else
      {Enum.uniq(seen), execution}
    end
  end

  defp collect_runnables(execution, collected) do
    if Exec.status(execution) == :running do
      ready = Exec.ready(execution)
      assert {:ok, _executed, execution} = Exec.wave(execution)
      collect_runnables(execution, collected ++ ready)
    else
      {collected, execution}
    end
  end
end
