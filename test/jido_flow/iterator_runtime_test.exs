defmodule Jido.Flow.IteratorRuntimeTest do
  use ExUnit.Case, async: true

  @moduletag capture_log: true

  alias Jido.Action.Error.{ExecutionFailureError, InvalidInputError}
  alias Jido.Action.Output
  alias Jido.Exec
  alias Jido.Flow.Ref
  alias JidoTest.IteratorFixtures
  alias JidoTest.IteratorFixtures.{Envelope, Increment, StateStruct}
  alias JidoTest.TestActions.CountedMapAction

  describe "bounded Iterator runtime" do
    test "completes at the head without starting a body" do
      flow =
        IteratorFixtures.iterator_flow(
          initial: %{count: Ref.value(0)},
          completion: IteratorFixtures.eq(Ref.state(:count), Ref.value(0)),
          max_iterations: 3
        )

      assert {:ok,
              %{
                kind: :jido_flow_iterate_result,
                iterations: 0,
                state: %{count: 0},
                output: nil
              }} = Exec.run(flow, %{}, %{test_pid: self()})

      refute_received {Increment, _index}
    end

    test "commits exactly three replacements and lets completion win at the bound" do
      flow =
        IteratorFixtures.iterator_flow(
          initial: %{count: Ref.value(0)},
          completion: IteratorFixtures.gte(Ref.state(:count), Ref.value(3)),
          max_iterations: 3
        )

      assert {:ok,
              %{
                kind: :jido_flow_iterate_result,
                iterations: 3,
                state: %{count: 3},
                output: %{count: 3}
              }} = Exec.run(flow, %{}, %{test_pid: self()})

      assert_receive {Increment, 0}
      assert_receive {Increment, 1}
      assert_receive {Increment, 2}
      refute_received {Increment, 3}
    end

    test "fails on exhaustion without starting an extra body" do
      flow =
        IteratorFixtures.iterator_flow(
          initial: %{count: Ref.value(0)},
          completion: IteratorFixtures.eq(Ref.value(false), Ref.value(true)),
          max_iterations: 2
        )

      assert {:error,
              %ExecutionFailureError{
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
          initial: %{count: Ref.value(0)},
          update: %{count: Ref.body_result([:value, :count])},
          completion: IteratorFixtures.gte(Ref.state(:count), Ref.value(1)),
          max_iterations: 1
        )

      assert {:ok, %{state: %{count: 1}, output: %Output{} = output}} = Exec.run(flow, %{}, %{})
      assert output.value == %{count: 1}
    end

    test "rejects an Action Output as a whole State replacement" do
      flow =
        IteratorFixtures.iterator_flow(
          action: Envelope,
          initial: %{count: Ref.value(0)},
          update: Ref.body_result(),
          completion: IteratorFixtures.eq(Ref.value(false), Ref.value(true)),
          max_iterations: 1
        )

      assert {:error,
              %ExecutionFailureError{
                message: "iterator state update must resolve to a plain map",
                details: %{
                  phase: :iterate_state_update,
                  node: "count",
                  iteration_index: 0,
                  state_revision: 0,
                  reason: :not_a_plain_map,
                  value_type: :action_output,
                  retry: false
                }
              }} = Exec.run(flow, %{}, %{})
    end

    test "rejects an Action Output as initial State" do
      flow =
        IteratorFixtures.iterator_flow(
          initial: Ref.value(Output.raw(%{count: 0})),
          completion: IteratorFixtures.eq(Ref.value(true), Ref.value(true)),
          max_iterations: 1
        )

      assert {:error,
              %ExecutionFailureError{
                message: "iterator initial state must resolve to a plain map",
                details: %{
                  phase: :iterate_state_initial,
                  reason: :not_a_plain_map,
                  value_type: :action_output
                }
              }} = Exec.run(flow, %{}, %{})
    end

    test "rejects non-map State and hides rejected State values" do
      flow =
        IteratorFixtures.iterator_flow(
          initial: Ref.value([]),
          completion: IteratorFixtures.eq(Ref.value(true), Ref.value(true)),
          max_iterations: 1
        )

      assert {:error,
              %ExecutionFailureError{
                message: "iterator initial state must resolve to a plain map",
                details: %{phase: :iterate_state_initial, reason: :not_a_plain_map}
              } = error} = Exec.run(flow, %{}, %{})

      refute Map.has_key?(error.details, :value)

      nil_flow =
        IteratorFixtures.iterator_flow(
          initial: Ref.value(nil),
          completion: IteratorFixtures.eq(Ref.value(true), Ref.value(true)),
          max_iterations: 1
        )

      assert {:error,
              %ExecutionFailureError{
                message: "iterator initial state must resolve to a plain map",
                details: %{value_type: nil}
              }} = Exec.run(nil_flow, %{}, %{})
    end

    test "returns a fixed State schema validation error" do
      schema = Zoi.object(%{count: Zoi.integer()})

      flow =
        IteratorFixtures.iterator_flow(
          schema: schema,
          initial: %{count: Ref.value(0)},
          update: %{count: Ref.value("bad")},
          completion: IteratorFixtures.eq(Ref.value(false), Ref.value(true)),
          max_iterations: 1
        )

      assert {:error,
              %InvalidInputError{
                message: "iterator state schema validation failed",
                details: %{
                  phase: :iterate_state_update,
                  node: "count",
                  iteration_index: 0,
                  state_revision: 0
                }
              } = error} = Exec.run(flow, %{}, %{})

      refute Map.has_key?(error.details, :errors)
      refute inspect(error.details) =~ "bad"
    end

    test "validates and invokes the body exactly once per iteration" do
      flow =
        IteratorFixtures.iterator_flow(
          action: CountedMapAction,
          input: %{test_pid: Ref.context(:test_pid), index: Ref.iteration_index()},
          initial: %{count: Ref.value(0)},
          update: %{count: Ref.state(:count)},
          completion: IteratorFixtures.gte(Ref.iteration_index(), Ref.value(1)),
          max_iterations: 1
        )

      assert {:ok, %{iterations: 1}} = Exec.run(flow, %{}, %{test_pid: self()})
      assert_receive {CountedMapAction, :input, 0}
      assert_receive {CountedMapAction, :run, 0}
      assert_receive {CountedMapAction, :output, 0}
      refute_received {CountedMapAction, _phase, 0}
    end

    test "rejects a State schema that transforms the value to a struct" do
      schema = Zoi.struct(StateStruct, %{count: Zoi.integer()}, coerce: true)

      flow =
        IteratorFixtures.iterator_flow(
          schema: schema,
          initial: %{count: Ref.value(0)},
          completion: IteratorFixtures.eq(Ref.value(true), Ref.value(true)),
          max_iterations: 1
        )

      assert {:error,
              %ExecutionFailureError{
                message: "iterator state schema must return a plain map",
                details: %{
                  phase: :iterate_state_initial,
                  reason: :not_a_plain_map,
                  value_type: :map,
                  state_revision: 0
                }
              }} = Exec.run(flow, %{}, %{})
    end

    test "keeps zero-completion and exhaustion as distinct runtime results" do
      zero =
        IteratorFixtures.iterator_flow(
          initial: %{count: Ref.value(0)},
          completion: IteratorFixtures.eq(Ref.value(true), Ref.value(true)),
          max_iterations: 1
        )

      assert {:ok, %{iterations: 0}} = Exec.run(zero, %{}, %{})

      exhausted =
        IteratorFixtures.iterator_flow(
          initial: %{count: Ref.value(0)},
          completion: IteratorFixtures.eq(Ref.value(false), Ref.value(true)),
          max_iterations: 1
        )

      assert {:error,
              %ExecutionFailureError{message: "flow iterator exhausted maximum iterations"}} =
               Exec.run(exhausted, %{}, %{})
    end
  end
end
