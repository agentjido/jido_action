defmodule JidoActionTest.Exec.IteratorExecutionTest do
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias Jido.Action.Error.ExecutionFailureError, as: ActionExecutionFailureError
  alias Jido.Action.Error.InvalidInputError
  alias Jido.Action.Output
  alias Jido.Exec
  alias Jido.Flow.Ref
  alias Jido.Flow.Error.ExecutionFailureError, as: FlowExecutionFailureError
  alias Jido.Flow.Error.InvalidExecutionError
  alias JidoActionTest.Fixtures.Iterator, as: IteratorFixtures

  alias JidoActionTest.Fixtures.{
    Envelope,
    FailsSecond,
    Increment,
    InvalidOutput,
    RetryableFailure,
    ReturnedException,
    StateStruct
  }

  alias JidoActionTest.Fixtures.Actions.CountedMapAction
  alias Jido.Exec.Work

  test "runs the State schema transform exactly once per candidate" do
    IteratorFixtures.register_state_schema_recorder(self())

    schema =
      Zoi.map()
      |> Zoi.transform({IteratorFixtures, :record_state_transform, []})

    flow =
      IteratorFixtures.iterator_flow(
        schema: schema,
        initial: %{count: 0},
        completion: IteratorFixtures.gte(Ref.iteration_index(), 1),
        max_iterations: 1
      )

    assert {:ok, %{iterations: 1, state: %{count: 201}, output: %{count: 101}}} =
             Exec.run(flow, %{}, %{})

    assert_receive {:state_schema_transform, %{count: 0}}
    assert_receive {:state_schema_transform, %{count: 101}}
    refute_received {:state_schema_transform, _candidate}
  end

  test "completes at the head without starting a body" do
    flow =
      IteratorFixtures.iterator_flow(
        initial: %{count: 0},
        completion: IteratorFixtures.eq(Ref.state(:count), 0),
        max_iterations: 3
      )

    assert Exec.run(flow, %{}, %{test_pid: self()}) ==
             {:ok,
              %{
                kind: :jido_flow_iterate_result,
                iterations: 0,
                state: %{count: 0},
                output: nil
              }}

    refute_received {Increment, _index}
  end

  test "commits replacements and lets completion win at the bound" do
    flow =
      IteratorFixtures.iterator_flow(
        initial: %{count: 0},
        completion: IteratorFixtures.gte(Ref.state(:count), 3),
        max_iterations: 3
      )

    assert {:ok, %{iterations: 3, state: %{count: 3}, output: %{count: 3}}} =
             Exec.run(flow, %{}, %{test_pid: self()})

    assert_receive {Increment, 0}
    assert_receive {Increment, 1}
    assert_receive {Increment, 2}
    refute_received {Increment, 3}
  end

  test "fails on exhaustion without an extra body call" do
    flow =
      IteratorFixtures.iterator_flow(
        initial: %{count: 0},
        completion: IteratorFixtures.eq(false, true),
        max_iterations: 2
      )

    assert {:error,
            %FlowExecutionFailureError{
              message: "flow iterator exhausted maximum iterations",
              details: %{
                phase: :iterate_exhaustion,
                node: "count",
                max_iterations: 2,
                completed_iterations: 2,
                state_revision: 2,
                retry: false
              }
            }} = Exec.run(flow, %{}, %{test_pid: self()})

    assert_receive {Increment, 0}
    assert_receive {Increment, 1}
    refute_received {Increment, 2}
  end

  test "preserves a valid Action Output as the latest body result" do
    flow =
      IteratorFixtures.iterator_flow(
        action: Envelope,
        initial: %{count: 0},
        update: %{count: Ref.body_result([:value, :count])},
        completion: IteratorFixtures.gte(Ref.state(:count), 1),
        max_iterations: 1
      )

    assert {:ok, %{state: %{count: 1}, output: %Output{} = output}} = Exec.run(flow)
    assert output.value == %{count: 1}
  end

  test "rejects an Action Output as a State value" do
    updated =
      IteratorFixtures.iterator_flow(
        action: Envelope,
        initial: %{count: 0},
        update: Ref.body_result(),
        completion: IteratorFixtures.eq(false, true),
        max_iterations: 1
      )

    assert {:error,
            %FlowExecutionFailureError{
              message: "iterator state update must resolve to a plain map",
              details: %{phase: :iterate_state_update, value_type: :action_output}
            }} = Exec.run(updated)

    initial =
      IteratorFixtures.iterator_flow(
        initial: Ref.input(:state),
        completion: IteratorFixtures.eq(true, true),
        max_iterations: 1
      )

    assert {:error,
            %FlowExecutionFailureError{
              message: "iterator initial state must resolve to a plain map",
              details: %{phase: :iterate_state_initial, value_type: :action_output}
            }} = Exec.run(initial, %{state: Output.raw(%{count: 0})})
  end

  test "rejects other non-map State values without leaking them" do
    for {initial, value_type} <- [{[], :list}, {nil, nil}] do
      flow =
        IteratorFixtures.iterator_flow(
          initial: initial,
          completion: IteratorFixtures.eq(true, true),
          max_iterations: 1
        )

      assert {:error,
              %FlowExecutionFailureError{
                message: "iterator initial state must resolve to a plain map",
                details: %{reason: :not_a_plain_map, value_type: ^value_type} = details
              }} = Exec.run(flow)

      refute Map.has_key?(details, :value)
    end
  end

  test "returns fixed State schema failures" do
    flow =
      IteratorFixtures.iterator_flow(
        schema: Zoi.object(%{count: Zoi.integer()}),
        initial: %{count: 0},
        update: %{count: "bad"},
        completion: IteratorFixtures.eq(false, true),
        max_iterations: 1
      )

    assert {:error,
            %InvalidExecutionError{
              message: "iterator state schema validation failed",
              details: %{phase: :iterate_state_update, iteration_index: 0, state_revision: 0}
            } = error} = Exec.run(flow)

    refute Map.has_key?(error.details, :errors)
    refute inspect(error.details) =~ "bad"
  end

  test "rejects a State schema that produces a struct" do
    flow =
      IteratorFixtures.iterator_flow(
        schema: Zoi.struct(StateStruct, %{count: Zoi.integer()}, coerce: true),
        initial: %{count: 0},
        completion: IteratorFixtures.eq(true, true),
        max_iterations: 1
      )

    assert {:error,
            %FlowExecutionFailureError{
              message: "iterator state schema must return a plain map",
              details: %{phase: :iterate_state_initial, reason: :not_a_plain_map}
            }} = Exec.run(flow)
  end

  test "validates and calls the body once per iteration" do
    flow =
      IteratorFixtures.iterator_flow(
        action: CountedMapAction,
        input: %{test_pid: Ref.context(:test_pid), index: Ref.iteration_index()},
        initial: %{count: 0},
        update: %{count: Ref.state(:count)},
        completion: IteratorFixtures.gte(Ref.iteration_index(), 1),
        max_iterations: 1
      )

    assert {:ok, %{iterations: 1}} = Exec.run(flow, %{}, %{test_pid: self()})
    assert_receive {CountedMapAction, :input, 0}
    assert_receive {CountedMapAction, :run, 0}
    assert_receive {CountedMapAction, :output, 0}
    refute_received {CountedMapAction, _phase, 0}
  end

  test "keeps prior effects but returns no partial State after body failure" do
    flow =
      IteratorFixtures.iterator_flow(
        action: FailsSecond,
        initial: %{count: 0},
        completion: IteratorFixtures.eq(false, true),
        max_iterations: 3
      )

    assert {:error,
            %ActionExecutionFailureError{
              message: "second body failed",
              details: %{
                phase: :iterate_body_execution,
                iteration_index: 1,
                state_revision: 1,
                retry: false
              }
            } = error} = Exec.run(flow, %{}, %{test_pid: self()})

    assert_receive {FailsSecond, 0}
    assert_receive {FailsSecond, 1}
    refute Map.has_key?(error.details, :state)
    refute Map.has_key?(error.details, :output)
  end

  test "preserves target retry policy but removes target-private details" do
    flow =
      IteratorFixtures.iterator_flow(
        action: RetryableFailure,
        initial: %{count: 0},
        completion: IteratorFixtures.eq(false, true),
        max_iterations: 1
      )

    assert {:error,
            %ActionExecutionFailureError{
              message: "retryable body failed",
              details: %{phase: :iterate_body_execution, retry: true}
            } = error} = Exec.run(flow)

    assert Jido.Action.Error.retryable?(error)
    refute Map.has_key?(error.details, :rejected_payload)
  end

  test "adds Iterate ownership to a returned exception" do
    flow =
      IteratorFixtures.iterator_flow(
        action: ReturnedException,
        initial: %{count: 0},
        completion: IteratorFixtures.eq(false, true),
        max_iterations: 1
      )

    assert {:error,
            %ActionExecutionFailureError{
              message: "returned body exception",
              details: %{phase: :iterate_body_execution, exception: RuntimeError}
            }} = Exec.run(flow)
  end

  test "preserves body input and output validation failures" do
    bad_input =
      IteratorFixtures.iterator_flow(
        input: %{count: "bad", index: Ref.iteration_index()},
        initial: %{count: 0},
        completion: IteratorFixtures.eq(false, true),
        max_iterations: 1
      )

    assert {:error, %InvalidInputError{details: %{phase: :iterate_body_input}}} =
             Exec.run(bad_input)

    bad_output =
      IteratorFixtures.iterator_flow(
        action: InvalidOutput,
        initial: %{count: 0},
        completion: IteratorFixtures.eq(false, true),
        max_iterations: 1
      )

    assert {:error, %InvalidInputError{details: %{phase: :iterate_body_output}}} =
             Exec.run(bad_output)
  end

  test "reports invalid completion before and after a commit" do
    initial_failure =
      IteratorFixtures.iterator_flow(
        initial: %{count: 0},
        completion: IteratorFixtures.gte(Ref.state(), 1),
        max_iterations: 1
      )

    assert {:error,
            %FlowExecutionFailureError{
              message: "invalid iterator completion condition operands",
              details: %{iterations: 0, reason: :invalid_ordering_operands}
            }} = Exec.run(initial_failure, %{}, %{test_pid: self()})

    refute_received {Increment, _index}

    committed_failure =
      IteratorFixtures.iterator_flow(
        initial: %{count: 0, guard: -1},
        update: %{count: Ref.body_result(:count), guard: %{}},
        completion: IteratorFixtures.gte(Ref.state(:guard), 0),
        max_iterations: 1
      )

    assert {:ok, execution} = Exec.start(committed_failure)
    assert {:ok, %Work{status: :failed}, execution} = Exec.step(execution)
    assert execution.revision == 1
    assert Exec.status(execution) == :failed
  end
end
