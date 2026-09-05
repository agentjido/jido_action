defmodule JidoActionTest.Exec.NativeFlowExecutionTest do
  use ExUnit.Case, async: true

  alias Jido.Exec
  alias Jido.Flow
  alias Jido.Flow.{Map, Reduce, Ref, Step, Subflow}
  alias JidoActionTest.Fixtures.{ChoicePublicPaths, MathFlow}
  alias JidoActionTest.Fixtures.ChildIterator
  alias JidoActionTest.Fixtures.InlineControlledFlow

  alias JidoActionTest.Fixtures.Actions.{
    EchoParamsAction,
    ErrorAction,
    RecorderAction,
    ReduceProbeAction
  }

  alias JidoActionTest.Fixtures.Execution, as: ExecFixtures

  alias Jido.Exec.Work

  test "full execution and step-wise execution return the same value" do
    assert {:ok, expected} = Exec.run(MathFlow, %{value: 3})
    assert {:ok, execution} = Exec.start(MathFlow, %{value: 3})
    assert [%Work{component_path: ["add_one"]} = first] = Exec.ready(execution)

    assert {:ok, %Work{token: token, status: :completed}, execution} =
             Exec.step(execution, first.token)

    assert token == first.token
    assert [%Work{component_path: ["double"]} = second] = Exec.ready(execution)
    assert {:ok, %Work{status: :completed}, execution} = Exec.step(execution, second.token)
    assert Exec.status(execution) == :succeeded
    assert Exec.result(execution) == {:ok, expected}
  end

  test "an older execution revision cannot dispatch the same work again" do
    assert {:ok, stale} = Exec.start(MathFlow, %{value: 3})
    assert {:ok, %Work{status: :completed}, current} = Exec.step(stale)
    assert current.revision == 1

    assert {:error,
            %Jido.Flow.Error.InvalidExecutionError{
              message: "stale flow execution",
              details: %{reason: :stale_revision, revision: 0, current_revision: 1}
            }} = Exec.step(stale)

    assert {:error,
            %Jido.Flow.Error.InvalidExecutionError{
              message: "stale flow execution",
              details: %{reason: :stale_revision, revision: 0, current_revision: 1}
            }} = Exec.continue(stale)
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

  test "a stale inline wave cannot repeat body effects" do
    token = make_ref()
    context = %{test_pid: self(), token: token, block: false}
    input = %{first: 1, second: 2, third: 3}
    assert {:ok, stale} = Exec.start(InlineControlledFlow, input, context, max_concurrency: 2)
    assert length(Exec.ready(stale)) == 3
    assert {:ok, executed, current} = Exec.wave(stale)

    assert Enum.map(executed, &hd(&1.component_path)) |> Enum.sort() == [
             "first",
             "second",
             "third"
           ]

    assert current.revision == 1

    for value <- 1..3 do
      assert_received {:inline_started, ^token, ^value, worker}
      monitor = Process.monitor(worker)
      assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 1_000
      assert_received {:inline_finished, ^token, ^value}
    end

    for mutate <- [&Exec.step/1, &Exec.wave/1, &Exec.continue/1] do
      assert {:error,
              %Jido.Flow.Error.InvalidExecutionError{
                message: "stale flow execution",
                details: %{reason: :stale_revision, revision: 0, current_revision: 1}
              }} = mutate.(stale)
    end

    refute_received {:inline_started, ^token, _value, _worker}
    refute_received {:inline_finished, ^token, _value}
    assert {:ok, completed} = Exec.continue(current)
    assert Exec.result(completed) == {:ok, %{values: [1, 2, 3]}}
  end

  test "ready, step, and wave expose support work" do
    flow = map_reduce_flow()
    assert {:ok, execution} = Exec.start(flow, %{items: [1, 2, 3]})
    {seen, execution} = run_waves(execution, [])

    assert Exec.result(execution) ==
             {:ok, %{values: [%{value: 1}, %{value: 2}, %{value: 3}], indexes: [0, 1, 2]}}

    assert :fan_out in seen
    assert :fan_in in seen
    assert :map_item in seen
  end

  test "a Subflow exposes its child and input binding work" do
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
      for %Work{component_path: path} <- runnables,
          do: path

    assert Enum.any?(runnables, &(&1.component_path == ["child"] and &1.role == :input))
    assert ["child", "add_one"] in names
    assert ["child", "double"] in names
    assert Enum.any?(runnables, &(&1.component_path == ["child"] and &1.role == :output))
    assert Enum.any?(runnables, &match?(%Work{role: :input_binding}, &1))
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
    assert Enum.any?(runnables, &match?(%Work{role: :join}, &1))
    assert Exec.result(execution) == {:ok, %{value: :only_authored_data}}
  end

  test "Choice keeps first-match and fallback behavior in one native Step" do
    assert Exec.run(ChoicePublicPaths, %{kind: :priority, value: 2}) == {:ok, %{value: 3}}
    assert Exec.run(ChoicePublicPaths, %{kind: :normal, value: 2}) == {:ok, %{value: 4}}
  end

  test "Iterate stays one bounded native Step" do
    assert {:ok, execution} = Exec.start(ChildIterator, %{start: 0, limit: 3})

    assert [%Work{component_path: ["child"], kind: :iterate, role: :execute}] =
             Exec.ready(execution)

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
      seen = seen ++ Enum.map(ready, & &1.role)
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
