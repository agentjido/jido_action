defmodule Jido.Flow.IteratorRuntimeTest do
  use ExUnit.Case, async: false

  alias Jido.Action
  alias Jido.Action.Error
  alias Jido.Action.Error.ExecutionFailureError
  alias Jido.Action.Error.InternalError
  alias Jido.Action.Error.InvalidInputError
  alias Jido.Action.Output
  alias Jido.Exec
  alias Jido.Exec.NodeResult
  alias Jido.Flow
  alias Jido.Flow.Compiler
  alias Jido.Flow.Condition
  alias Jido.Flow.Iterator
  alias Jido.Flow.Map, as: FlowMap
  alias Jido.Flow.Ref
  alias JidoTest.TestActions.CountedMapAction

  @state_schema_recorder :jido_flow_iterator_runtime_state_schema_recorder

  def record_state_transform(value, _opts) do
    if owner = Process.whereis(@state_schema_recorder) do
      send(owner, {:state_schema_transform, value})
    end

    {:ok, Map.update!(value, :count, &(&1 + 100))}
  end

  defmodule Increment do
    use Action,
      name: "iterator_increment",
      schema: Zoi.object(%{count: Zoi.integer(), index: Zoi.integer()}),
      output_schema: Zoi.object(%{count: Zoi.integer()})

    @impl true
    def run(%{count: count, index: index}, context) do
      if is_pid(context[:test_pid]), do: send(context.test_pid, {__MODULE__, index})
      {:ok, %{count: count + 1}}
    end
  end

  defmodule Envelope do
    use Action,
      name: "iterator_envelope",
      schema: Zoi.object(%{count: Zoi.integer(), index: Zoi.integer()})

    @impl true
    def run(%{count: count}, _context) do
      {:ok, Output.raw(%{count: count + 1}, meta: %{source: :iterate_test})}
    end
  end

  defmodule FailsSecond do
    use Action,
      name: "iterator_fails_second",
      schema: Zoi.object(%{count: Zoi.integer(), index: Zoi.integer()}),
      output_schema: Zoi.object(%{count: Zoi.integer()})

    @impl true
    def run(%{index: index} = params, context) do
      if is_pid(context[:test_pid]), do: send(context.test_pid, {__MODULE__, index})

      if index == 1 do
        {:error, "second body failed"}
      else
        {:ok, %{count: params.count + 1}}
      end
    end
  end

  defmodule RetryableFailure do
    use Action,
      name: "iterator_retryable_failure",
      schema: Zoi.object(%{count: Zoi.integer(), index: Zoi.integer()})

    @impl true
    def run(_params, _context) do
      {:error,
       Error.execution_error("retryable body failed", %{
         retry: true,
         rejected_payload: %{secret: "must not leave the target boundary"}
       })}
    end
  end

  defmodule ReturnedException do
    use Action,
      name: "iterator_returned_exception",
      schema: Zoi.object(%{count: Zoi.integer(), index: Zoi.integer()})

    @impl true
    def run(_params, _context), do: {:error, RuntimeError.exception("returned body exception")}
  end

  defmodule InvalidOutput do
    use Action,
      name: "iterator_invalid_output",
      schema: Zoi.object(%{count: Zoi.integer(), index: Zoi.integer()}),
      output_schema: Zoi.object(%{count: Zoi.integer()})

    @impl true
    def run(_params, _context), do: {:ok, %{count: "bad"}}
  end

  defmodule BrokenFlow do
    use Action, name: "iterator_broken_flow"

    def __jido_flow__, do: true
    def flow, do: raise("broken nested Flow")

    @impl true
    def run(params, _context), do: {:ok, params}
  end

  defmodule StateStruct do
    @enforce_keys [:count]
    defstruct [:count]
  end

  defmodule ChildIterator do
    use Flow, name: "child_iterator"

    flow do
      iterate "child" do
        state([], initial: %{count: 0})
        action(Jido.Flow.IteratorRuntimeTest.Increment)
        params(%{count: state(:count), index: iteration_index()})
        update(%{count: body_result(:count)})
        repeat(1)
      end
    end
  end

  defmodule ChildMapReduce do
    use Flow, name: "child_map_reduce"

    flow do
      map("enrich",
        collection: input(:items),
        action: JidoTest.TestActions.Add,
        params: %{value: item(:value), amount: 1}
      )

      reduce "summarize" do
        collection(result("enrich"))
        initial(%{value: 1})
        action(JidoTest.TestActions.Multiply)
        params(%{value: accumulator(:value), amount: item(:value)})
      end
    end
  end

  describe "bounded Iterator runtime" do
    test "completes at the head without starting a body" do
      flow =
        iterator_flow(
          initial: %{count: Ref.value(0)},
          completion: eq(Ref.state(:count), Ref.value(0)),
          max_iterations: 3
        )

      assert {:ok,
              %{
                kind: :jido_flow_iterate_result,
                iterations: 0,
                state: %{count: 0},
                output: nil
              }} = Exec.run(flow, %{}, %{test_pid: self()})

      refute_receive {Increment, _index}
    end

    test "commits exactly three replacements and lets completion win at the bound" do
      flow =
        iterator_flow(
          initial: %{count: Ref.value(0)},
          completion: gte(Ref.state(:count), Ref.value(3)),
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
      refute_receive {Increment, 3}
    end

    test "fails on exhaustion without starting an extra body" do
      flow =
        iterator_flow(
          initial: %{count: Ref.value(0)},
          completion: eq(Ref.value(false), Ref.value(true)),
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
      refute_receive {Increment, 2}
    end

    test "preserves a valid Action Output as the latest body result" do
      flow =
        iterator_flow(
          action: Envelope,
          initial: %{count: Ref.value(0)},
          update: %{count: Ref.body_result([:value, :count])},
          completion: gte(Ref.state(:count), Ref.value(1)),
          max_iterations: 1
        )

      assert {:ok, %{state: %{count: 1}, output: %Output{} = output}} = Exec.run(flow, %{}, %{})
      assert output.value == %{count: 1}
    end

    test "rejects an Action Output as a whole State replacement" do
      flow =
        iterator_flow(
          action: Envelope,
          initial: %{count: Ref.value(0)},
          update: Ref.body_result(),
          completion: eq(Ref.value(false), Ref.value(true)),
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
        iterator_flow(
          initial: Ref.value(Output.raw(%{count: 0})),
          completion: eq(Ref.value(true), Ref.value(true)),
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
        iterator_flow(
          initial: Ref.value([]),
          completion: eq(Ref.value(true), Ref.value(true)),
          max_iterations: 1
        )

      assert {:error,
              %ExecutionFailureError{
                message: "iterator initial state must resolve to a plain map",
                details: %{phase: :iterate_state_initial, reason: :not_a_plain_map}
              } = error} = Exec.run(flow, %{}, %{})

      refute Map.has_key?(error.details, :value)

      nil_flow =
        iterator_flow(
          initial: Ref.value(nil),
          completion: eq(Ref.value(true), Ref.value(true)),
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
        iterator_flow(
          schema: schema,
          initial: %{count: Ref.value(0)},
          update: %{count: Ref.value("bad")},
          completion: eq(Ref.value(false), Ref.value(true)),
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

    test "runs the State schema transform exactly once per candidate" do
      Process.register(self(), @state_schema_recorder)

      schema =
        Zoi.map()
        |> Zoi.transform({__MODULE__, :record_state_transform, []})

      flow =
        iterator_flow(
          schema: schema,
          initial: %{count: Ref.value(0)},
          completion: gte(Ref.iteration_index(), Ref.value(1)),
          max_iterations: 1
        )

      assert {:ok, %{iterations: 1, state: %{count: 201}, output: %{count: 101}}} =
               Exec.run(flow, %{}, %{})

      assert_receive {:state_schema_transform, %{count: 0}}
      assert_receive {:state_schema_transform, %{count: 101}}
      refute_receive {:state_schema_transform, _candidate}
    end

    test "validates and invokes the body exactly once per iteration" do
      flow =
        iterator_flow(
          action: CountedMapAction,
          input: %{test_pid: Ref.context(:test_pid), index: Ref.iteration_index()},
          initial: %{count: Ref.value(0)},
          update: %{count: Ref.state(:count)},
          completion: gte(Ref.iteration_index(), Ref.value(1)),
          max_iterations: 1
        )

      assert {:ok, %{iterations: 1}} = Exec.run(flow, %{}, %{test_pid: self()})
      assert_receive {CountedMapAction, :input, 0}
      assert_receive {CountedMapAction, :run, 0}
      assert_receive {CountedMapAction, :output, 0}
      refute_receive {CountedMapAction, _phase, 0}
    end

    test "rejects a State schema that transforms the value to a struct" do
      schema = Zoi.struct(StateStruct, %{count: Zoi.integer()}, coerce: true)

      flow =
        iterator_flow(
          schema: schema,
          initial: %{count: Ref.value(0)},
          completion: eq(Ref.value(true), Ref.value(true)),
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

    test "keeps prior effects but returns no partial State after a body failure" do
      flow =
        iterator_flow(
          action: FailsSecond,
          initial: %{count: Ref.value(0)},
          completion: eq(Ref.value(false), Ref.value(true)),
          max_iterations: 3
        )

      assert {:error,
              %ExecutionFailureError{
                message: "second body failed",
                details: %{
                  phase: :iterate_body_execution,
                  node: "count",
                  target: FailsSecond,
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

    test "preserves an explicit target retry policy without target error details" do
      flow =
        iterator_flow(
          action: RetryableFailure,
          initial: %{count: Ref.value(0)},
          completion: eq(Ref.value(false), Ref.value(true)),
          max_iterations: 1
        )

      assert {:error,
              %ExecutionFailureError{
                message: "retryable body failed",
                details: %{
                  phase: :iterate_body_execution,
                  node: "count",
                  target: RetryableFailure,
                  iteration_index: 0,
                  state_revision: 0,
                  retry: true
                }
              } = error} = Exec.run(flow, %{}, %{})

      assert Error.retryable?(error)
      refute Map.has_key?(error.details, :rejected_payload)
    end

    test "adds bounded ownership details to a returned standard exception" do
      flow =
        iterator_flow(
          action: ReturnedException,
          initial: %{count: Ref.value(0)},
          completion: eq(Ref.value(false), Ref.value(true)),
          max_iterations: 1
        )

      assert {:error, %RuntimeError{message: "returned body exception"} = error} =
               Exec.run(flow, %{}, %{})

      assert %{
               phase: :iterate_body_execution,
               node: "count",
               target: ReturnedException,
               iteration_index: 0,
               state_revision: 0,
               retry: false
             } = error_details(error)
    end

    test "preserves bounded body input and output validation failures" do
      bad_input =
        iterator_flow(
          input: %{count: Ref.value("bad"), index: Ref.iteration_index()},
          initial: %{count: Ref.value(0)},
          completion: eq(Ref.value(false), Ref.value(true)),
          max_iterations: 1
        )

      assert {:error,
              %InvalidInputError{
                details: %{
                  phase: :iterate_body_input,
                  node: "count",
                  target: Increment,
                  iteration_index: 0,
                  state_revision: 0,
                  retry: false
                }
              }} = Exec.run(bad_input, %{}, %{})

      bad_output =
        iterator_flow(
          action: InvalidOutput,
          initial: %{count: Ref.value(0)},
          completion: eq(Ref.value(false), Ref.value(true)),
          max_iterations: 1
        )

      assert {:error,
              %InvalidInputError{
                details: %{
                  phase: :iterate_body_output,
                  node: "count",
                  target: InvalidOutput,
                  iteration_index: 0,
                  state_revision: 0,
                  retry: false
                }
              }} = Exec.run(bad_output, %{}, %{})
    end

    test "normalizes an unexpected body adapter defect" do
      flow =
        iterator_flow(
          action: BrokenFlow,
          initial: %{count: Ref.value(0)},
          completion: eq(Ref.value(false), Ref.value(true)),
          max_iterations: 1
        )

      assert {:error,
              %InternalError{
                message: "flow iterator adapter failed",
                details: %{
                  phase: :iterate_internal,
                  node: "count",
                  iteration_index: 0,
                  state_revision: 0,
                  error_type: RuntimeError,
                  retry: false
                }
              }} = Exec.run(flow, %{}, %{})
    end

    test "rejects invalid completion operands before the first body" do
      flow =
        iterator_flow(
          initial: %{count: Ref.value(0)},
          completion: gte(Ref.state(), Ref.value(1)),
          max_iterations: 1
        )

      assert {:error,
              %ExecutionFailureError{
                message: "invalid iterator completion condition operands",
                details: %{
                  phase: :iterate_completion,
                  node: "count",
                  operator: :gte,
                  reason: :invalid_ordering_operands,
                  left_type: :map,
                  right_type: :number,
                  iterations: 0,
                  retry: false
                }
              }} = Exec.run(flow, %{}, %{test_pid: self()})

      refute_receive {Increment, _index}
    end

    test "reports a post-commit completion failure at the committed iteration count" do
      flow =
        iterator_flow(
          initial: %{count: Ref.value(0), guard: Ref.value(-1)},
          update: %{count: Ref.body_result(:count), guard: Ref.value(%{})},
          completion: gte(Ref.state(:guard), Ref.value(0)),
          max_iterations: 1
        )

      assert {:ok, execution} = Exec.start(flow)

      assert {:ok,
              %NodeResult{
                status: :error,
                output: nil,
                error: %ExecutionFailureError{
                  message: "invalid iterator completion condition operands",
                  details: %{
                    phase: :iterate_completion,
                    node: "count",
                    operator: :gte,
                    reason: :invalid_ordering_operands,
                    left_type: :map,
                    right_type: :number,
                    iterations: 1,
                    retry: false
                  }
                }
              }, failed_execution} = Exec.step(execution)

      assert failed_execution.revision == 1
      assert Exec.status(failed_execution) == :failed
    end

    test "runs a marked child Flow atomically with fresh child Iterator State" do
      flow =
        iterator_flow(
          action: ChildIterator,
          initial: %{count: Ref.value(0)},
          update: %{count: Ref.state(:count)},
          completion: gte(Ref.iteration_index(), Ref.value(2)),
          max_iterations: 2
        )

      assert {:ok,
              %{
                iterations: 2,
                state: %{count: 0},
                output: %{iterations: 1, state: %{count: 1}}
              }} = Exec.run(flow, %{}, %{test_pid: self()}, async: true, max_concurrency: 4)

      assert_receive {Increment, 0}
      assert_receive {Increment, 0}
      refute_receive {Increment, 1}
    end

    test "allows nested Map and Reduce to return one serial State candidate" do
      iterator =
        Iterator.new!(
          name: :aggregate,
          action: ChildMapReduce,
          input: %{items: Ref.state(:items)},
          state: [
            schema: [],
            initial: %{items: Ref.input(:items), total: Ref.value(0)},
            update: %{items: Ref.state(:items), total: Ref.body_result(:value)}
          ],
          completion: gte(Ref.iteration_index(), Ref.value(1)),
          max_iterations: 1
        )

      flow =
        Flow.new!(name: "iterator_map_reduce", nodes: [iterator], return: Ref.result(:aggregate))

      assert {:ok,
              %{
                iterations: 1,
                state: %{items: [%{value: 1}, %{value: 2}], total: 6},
                output: %{value: 6}
              }} = Exec.run(flow, %{items: [%{value: 1}, %{value: 2}]}, %{})
    end

    test "creates fresh child Iterator State for every Map item" do
      map =
        FlowMap.new!(
          name: :per_item,
          collection: Ref.input(:items),
          action: ChildIterator,
          input: %{item: Ref.item()}
        )

      flow = Flow.new!(name: "map_child_iterators", nodes: [map], return: Ref.result(:per_item))

      assert {:ok, %{results: results, errors: []}} =
               Exec.run(
                 flow,
                 %{items: [%{seed: 10}, %{seed: 20}]},
                 %{test_pid: self()},
                 async: true,
                 max_concurrency: 2
               )

      assert Enum.map(results, & &1.output.state) == [%{count: 1}, %{count: 1}]
      assert Enum.map(results, & &1.output.iterations) == [1, 1]
      assert_receive {Increment, 0}
      assert_receive {Increment, 0}
      refute_receive {Increment, 1}
    end

    test "is one public step and concurrent stale Execution reuse stays isolated" do
      flow =
        iterator_flow(
          initial: %{count: Ref.value(0)},
          completion: gte(Ref.state(:count), Ref.value(1)),
          max_iterations: 1
        )

      assert {:ok, execution} = Exec.start(flow, %{}, %{test_pid: self()})
      assert Exec.ready(execution) == ["count"]

      first_task = Task.async(fn -> Exec.step(execution) end)
      second_task = Task.async(fn -> Exec.step(execution) end)

      assert {:ok, %NodeResult{node: "count", status: :ok}, first} = Task.await(first_task)
      assert {:ok, %NodeResult{node: "count", status: :ok}, second} = Task.await(second_task)
      assert first.revision == 1
      assert second.revision == 1
      assert Exec.result(first) == Exec.result(second)
      assert_receive {Increment, 0}
      assert_receive {Increment, 0}
    end

    test "evaluates completion exactly once at the head and after each commit" do
      flow =
        iterator_flow(
          initial: %{count: Ref.value(0)},
          completion: gte(Ref.state(:count), Ref.value(3)),
          max_iterations: 3
        )

      target = {Compiler, :evaluate_iterator_completion, 3}

      :erlang.trace_pattern(target, true, [:local, :call_count])

      result =
        try do
          result = Exec.run(flow, %{}, %{})
          assert {:call_count, 4} = :erlang.trace_info(target, :call_count)
          result
        after
          :erlang.trace_pattern(target, false, [:local, :call_count])
        end

      assert {:ok, %{iterations: 3}} = result
    end

    test "runs independent Iterator nodes with isolated State cells in one async wave" do
      left =
        Iterator.new!(
          name: :left,
          action: Increment,
          input: %{count: Ref.state(:count), index: Ref.iteration_index()},
          state: [
            schema: [],
            initial: %{count: Ref.value(0)},
            update: %{count: Ref.body_result(:count)}
          ],
          completion: gte(Ref.iteration_index(), Ref.value(1)),
          max_iterations: 1
        )

      right =
        Iterator.new!(
          name: :right,
          action: Increment,
          input: %{count: Ref.state(:count), index: Ref.iteration_index()},
          state: [
            schema: [],
            initial: %{count: Ref.value(10)},
            update: %{count: Ref.body_result(:count)}
          ],
          completion: gte(Ref.iteration_index(), Ref.value(1)),
          max_iterations: 1
        )

      flow =
        Flow.new!(
          name: "parallel_iterators",
          nodes: [right, left],
          return: %{left: Ref.result(:left), right: Ref.result(:right)}
        )

      assert {:ok, execution} = Exec.start(flow, %{}, %{}, async: true, max_concurrency: 2)
      assert Exec.ready(execution) == ["left", "right"]

      assert {:ok, [left_result, right_result], execution} = Exec.wave(execution)
      assert left_result.output.state == %{count: 1}
      assert right_result.output.state == %{count: 11}
      assert Exec.status(execution) == :succeeded
    end

    test "keeps zero-completion and exhaustion as distinct runtime results" do
      zero =
        iterator_flow(
          initial: %{count: Ref.value(0)},
          completion: eq(Ref.value(true), Ref.value(true)),
          max_iterations: 1
        )

      assert {:ok, %{iterations: 0}} = Exec.run(zero, %{}, %{})

      exhausted =
        iterator_flow(
          initial: %{count: Ref.value(0)},
          completion: eq(Ref.value(false), Ref.value(true)),
          max_iterations: 1
        )

      assert {:error,
              %ExecutionFailureError{message: "flow iterator exhausted maximum iterations"}} =
               Exec.run(exhausted, %{}, %{})
    end
  end

  defp iterator_flow(opts) do
    action = Keyword.get(opts, :action, Increment)
    schema = Keyword.get(opts, :schema, [])

    input =
      Keyword.get(opts, :input, %{count: Ref.state(:count), index: Ref.iteration_index()})

    initial = Keyword.fetch!(opts, :initial)
    update = Keyword.get(opts, :update, %{count: Ref.body_result(:count)})
    completion = Keyword.fetch!(opts, :completion)
    max_iterations = Keyword.fetch!(opts, :max_iterations)

    iterator =
      Iterator.new!(
        name: :count,
        action: action,
        input: input,
        state: [schema: schema, initial: initial, update: update],
        completion: completion,
        max_iterations: max_iterations
      )

    Flow.new!(name: "iterator_runtime", nodes: [iterator], return: Ref.result(:count))
  end

  defp eq(left, right), do: %Condition{operator: :eq, operands: [left, right]}
  defp gte(left, right), do: %Condition{operator: :gte, operands: [left, right]}
  defp error_details(error), do: error |> Map.to_list() |> Keyword.fetch!(:details)
end
