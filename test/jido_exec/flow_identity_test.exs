defmodule JidoActionTest.Exec.FlowIdentityTest do
  use ExUnit.Case, async: true

  alias Jido.{Exec, Flow}
  alias Jido.Exec.Work
  alias Jido.Flow.{Ref, Step}
  alias Jido.Flow.Compiler.Payload
  alias Jido.Flow.Error.{ExecutionFailureError, InvalidExecutionError}
  alias JidoActionTest.Fixtures.Actions.{Add, EchoParamsAction}
  alias Runic.Workflow
  alias Runic.Workflow.{Fact, IdentityConflictError, Runnable}
  alias Runic.Workflow.Step, as: RunicStep

  test "the published Runic dependency separates the reported OTP 29 fact collision" do
    left =
      RunicStep.new(name: "left", hash: "probe-step-11396", work: fn _ -> %{value: 11_396} end)

    right =
      RunicStep.new(name: "right", hash: "probe-step-19508", work: fn _ -> %{value: 19_508} end)

    workflow =
      Workflow.new("two_fact_collision")
      |> Workflow.add(left)
      |> Workflow.add(right)
      |> Workflow.plan_eagerly(%{})

    {workflow, runnables} = Workflow.prepare_for_dispatch(workflow)

    workflow =
      Enum.reduce(["left", "right"], workflow, fn name, workflow ->
        executed = runnables |> Enum.find(&(&1.node.name == name)) |> Workflow.execute_runnable()
        Workflow.apply_runnable(workflow, executed)
      end)

    assert %{
             "left" => [%Fact{value: %{value: 11_396}}],
             "right" => [%Fact{value: %{value: 19_508}}]
           } =
             Workflow.results(workflow, ["left", "right"], facts: true, all: true)
  end

  for mutation <- [:step, :wave, :continue], phase <- [:first, :final] do
    @tag mutation: mutation, phase: phase
    test "#{mutation} returns a terminal error for a conflict at the #{phase} node", %{
      mutation: mutation,
      phase: phase
    } do
      assert {:ok, execution} = Exec.start(serial_flow(2), %{value: 0})
      handler = make_ref()
      events = [[:jido, :flow, :error], [:jido, :flow, :node, :start]]

      :ok =
        :telemetry.attach_many(
          handler,
          events,
          &__MODULE__.handle_event/4,
          {self(), execution.id}
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      execution =
        if phase == :final do
          assert {:ok, [_], next} = Exec.wave(execution)
          assert_received {[:jido, :flow, :node, :start], %{node: "step_1"}}
          next
        else
          execution
        end

      [runnable] = Exec.native(execution).ready
      # Add is pure. Calculate its Fact identity, then insert different data there.
      %Runnable{status: :completed, result: result} = Workflow.execute_runnable(runnable)
      %Payload{value: {:jido_flow_value, frame, _}} = result.value
      stale = %{result | value: Payload.new({:jido_flow_value, frame, %{value: 781}})}
      graph = Multigraph.add_vertex(execution.workflow.graph, stale)
      execution = %{execution | workflow: %{execution.workflow | graph: graph}}

      completed =
        case apply(Exec, mutation, [execution]) do
          {:ok, next} -> next
          {:ok, _, next} -> next
        end

      assert Exec.status(completed) == :failed
      assert Exec.ready(completed) == []

      assert {:error,
              %ExecutionFailureError{
                details: %{phase: :flow_identity, cause: IdentityConflictError, retry: false}
              } = error} = Exec.result(completed)

      assert error.details.identity == result.hash
      assert %Splode.Stacktrace{stacktrace: stacktrace} = error.stacktrace

      assert Enum.any?(stacktrace, fn
               {Runic.Workflow.Private, :log_fact, _, _} -> true
               _ -> false
             end)

      identity_text = Runic.Identity.to_string(result.hash)

      assert %{
               type: :flow_execution_error,
               details: %{
                 identity: ^identity_text,
                 existing: %{hash: ^identity_text},
                 incoming: %{hash: ^identity_text}
               }
             } = Flow.Error.to_map(error)

      assert {:ok, ^completed} = Exec.continue(completed)

      assert {:error, %InvalidExecutionError{message: "stale flow execution"}} =
               Exec.continue(execution)

      assert_received {[:jido, :flow, :error], %{execution_id: id, error: ^error}}
      assert id == completed.id
      refute_received {[:jido, :flow, :error], %{execution_id: ^id}}
      if phase == :first, do: refute_received({[:jido, :flow, :node, :start], %{node: "step_2"}})
    end
  end

  test "a conflict stops later graph commits in an already executed wave" do
    flow =
      Flow.new!(
        name: "parallel_conflict",
        components: [
          Step.new!(name: "left", action: Add, params: %{value: 1}),
          Step.new!(name: "right", action: Add, params: %{value: 2})
        ],
        output: %{left: Ref.result("left"), right: Ref.result("right")}
      )

    assert {:ok, execution} = Exec.start(flow)
    [first, second] = Exec.native(execution).ready
    first_result = Workflow.execute_runnable(first).result
    second_result = Workflow.execute_runnable(second).result
    stale = %{first_result | value: Payload.new(:conflicting_value)}

    execution = %{
      execution
      | workflow: %{
          execution.workflow
          | graph: Multigraph.add_vertex(execution.workflow.graph, stale)
        }
    }

    assert {:ok, [_, _], completed} = Exec.wave(execution)

    assert {:error, %ExecutionFailureError{details: %{phase: :flow_identity}}} =
             Exec.result(completed)

    refute Map.has_key?(Exec.native(completed).workflow.graph.vertices, second_result.hash)
  end

  test "a Map collector conflict becomes a terminal Jido error" do
    flow =
      Flow.new!(
        name: "collector_conflict",
        components: [
          Jido.Flow.Map.new!(
            name: "mapped",
            action: Add,
            collection: Ref.input(:items),
            params: %{value: Ref.item()}
          )
        ],
        output: %{items: Ref.result("mapped")}
      )

    assert {:ok, execution} = Exec.start(flow, %{items: [1]})
    execution = advance_to_collector(execution)
    [runnable] = Exec.native(execution).ready
    preview = Workflow.apply_runnable(execution.workflow, Workflow.execute_runnable(runnable))

    [%Fact{} = produced] =
      preview.graph.vertices
      |> Map.drop(Map.keys(execution.workflow.graph.vertices))
      |> Map.values()
      |> Enum.filter(&match?(%Fact{}, &1))

    stale = %{produced | value: []}

    execution = %{
      execution
      | workflow: %{
          execution.workflow
          | graph: Multigraph.add_vertex(execution.workflow.graph, stale)
        }
    }

    assert {:ok, [_], completed} = Exec.wave(execution)
    assert Exec.status(completed) == :failed
    assert Exec.ready(completed) == []

    assert {:error, %ExecutionFailureError{details: %{phase: :flow_identity, identity: identity}}} =
             Exec.result(completed)

    assert identity == produced.hash
  end

  test "native identities remain available through explicit inspection" do
    assert {:ok, execution} = Exec.start(serial_flow(1), %{value: 0})
    [runnable] = Exec.native(execution).ready
    assert %Runic.Identity{domain: :activation, digest: digest} = runnable.id
    assert byte_size(digest) == 32
    [work] = Exec.ready(execution)
    assert {:ok, %Work{status: :completed}, completed} = Exec.step(execution, work.token)
    assert Exec.result(completed) == {:ok, %{value: 1}}
  end

  test "Flow input and dependent results preserve local BEAM terms" do
    flow =
      Flow.new!(
        name: "local_values",
        components: [
          Step.new!(name: "first", action: EchoParamsAction, params: Ref.input([])),
          Step.new!(name: "second", action: EchoParamsAction, params: Ref.result("first"))
        ],
        output: Ref.result("second")
      )

    input = %{
      pid: self(),
      ref: make_ref(),
      function: fn value -> value end,
      struct: MapSet.new([:a]),
      improper: [1 | 2]
    }

    assert Exec.run(flow, input) == {:ok, input}
    assert {:ok, execution} = Exec.start(flow, input)
    assert {:ok, _, execution} = Exec.step(execution)
    assert {:ok, _, execution} = Exec.step(execution)
    assert Exec.result(execution) == {:ok, input}
  end

  test "native IDs and changed native work are rejected without consuming the revision" do
    assert {:ok, execution} = Exec.start(serial_flow(1), %{value: 0})
    [runnable] = Exec.native(execution).ready
    [work] = Exec.ready(execution)

    changed = %{
      runnable
      | node: %{runnable.node | work: fn _, _ -> flunk("changed work ran") end}
    }

    for selection <- [
          Runic.Identity.digest(:activation, :not_ready),
          runnable.input_fact.hash,
          %{runnable.id | digest: nil},
          runnable.id,
          changed
        ] do
      assert {:error, %InvalidExecutionError{} = error} = Exec.step(execution, selection)
      assert is_binary(JSON.encode!(error))
      assert Exec.ready(execution) == [work]
    end

    assert {:ok, completed_work, completed} = Exec.step(execution, work.token)
    assert completed_work == %{work | status: :completed}
    assert Exec.result(completed) == {:ok, %{value: 1}}
    assert completed.revision == execution.revision + 1
  end

  test "Map and Reduce preserve repeated local values and accumulator order" do
    flow =
      Flow.new!(
        name: "local_collection_values",
        components: [
          Jido.Flow.Map.new!(
            name: "mapped",
            action: EchoParamsAction,
            collection: Ref.input(:items),
            params: %{value: Ref.item()}
          ),
          Jido.Flow.Reduce.new!(
            name: "folded",
            action: EchoParamsAction,
            collection: Ref.result("mapped"),
            initial: Ref.input(:initial),
            params: %{current: Ref.item(:value), previous: Ref.accumulator()}
          )
        ],
        output: %{items: Ref.result("mapped"), folded: Ref.result("folded")}
      )

    shared = %{pid: self(), ref: make_ref(), callback: fn x -> x end, bits: <<1::1>>}
    initial = %{seed: make_ref()}

    for items <- [[], [shared, shared, %{shared | ref: make_ref()}]], concurrency <- [1, 4] do
      input = %{items: items, initial: initial}
      context = %{owner: self(), callback: fn -> :ok end}
      expected = Enum.reduce(items, initial, &%{current: &1, previous: &2})

      assert Exec.run(flow, input, context, max_concurrency: concurrency) ==
               {:ok, %{items: Enum.map(items, &%{value: &1}), folded: expected}}
    end
  end

  test "Map and Reduce facts exclude runtime services" do
    flow =
      Flow.new!(
        name: "collection_fact_data",
        components: [
          Jido.Flow.Map.new!(
            name: "mapped",
            action: EchoParamsAction,
            collection: Ref.input(:items),
            params: %{value: Ref.item()}
          ),
          Jido.Flow.Reduce.new!(
            name: "sum",
            action: Add,
            collection: Ref.result("mapped"),
            initial: %{value: 0},
            params: %{value: Ref.accumulator(:value), amount: Ref.item(:value)}
          )
        ],
        output: %{items: Ref.result("mapped"), sum: Ref.result("sum")}
      )

    for items <- [[], [1, 2]] do
      assert {:ok, execution} = Exec.start(flow, %{items: items}, %{owner: self()})
      assert {:ok, execution} = Exec.continue(execution)

      assert Exec.result(execution) ==
               {:ok, %{items: Enum.map(items, &%{value: &1}), sum: %{value: Enum.sum(items)}}}

      tokens =
        for %Fact{value: value} <- Map.values(Exec.native(execution).workflow.graph.vertices),
            %Payload{value: %{kind: kind} = token} <- List.wrap(value),
            kind in [:empty, :item, :result, :init],
            do: token

      assert tokens != []
      for token <- tokens, do: refute(Map.has_key?(token, :runtime))
    end
  end

  test "1,000 serial nodes complete through step with each correct result" do
    assert {:ok, execution} = Exec.start(serial_flow(1_000), %{value: 0})

    execution =
      Enum.reduce(1..1_000, execution, fn index, current ->
        name = "step_#{index}"
        assert [%Work{component_path: [^name]}] = Exec.ready(current)
        assert {:ok, %Work{status: :completed}, next} = Exec.step(current)

        assert %{^name => [%Fact{value: value}]} =
                 Workflow.results(Exec.native(next).workflow, [name], facts: true, all: true)

        assert {:jido_flow_value, _, %{value: ^index}} = Payload.unwrap(value)
        next
      end)

    assert Exec.status(execution) == :succeeded
    assert Exec.result(execution) == {:ok, %{value: 1_000}}
  end

  test "1,000 serial nodes complete through continue" do
    assert {:ok, execution} = Exec.start(serial_flow(1_000), %{value: 0})
    assert {:ok, execution} = Exec.continue(execution)
    assert Exec.status(execution) == :succeeded
    assert Exec.result(execution) == {:ok, %{value: 1_000}}
  end

  defp advance_to_collector(execution) do
    case Exec.ready(execution) do
      [%Work{role: :fan_in}] ->
        execution

      [_] ->
        assert {:ok, _, next} = Exec.step(execution)
        advance_to_collector(next)
    end
  end

  defp serial_flow(count) do
    Flow.new!(
      name: "identity_serial_#{count}",
      components:
        Enum.map(1..count, fn index ->
          source =
            if index == 1, do: Ref.input(:value), else: Ref.result("step_#{index - 1}", [:value])

          Step.new!(name: "step_#{index}", action: Add, params: %{value: source, amount: 1})
        end),
      output: Ref.result("step_#{count}")
    )
  end

  @doc false
  def handle_event(event, _measurements, %{execution_id: id} = metadata, {pid, id}) do
    send(pid, {event, metadata})
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok
end
