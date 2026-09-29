defmodule JidoActionTest.Exec.EffectsTest do
  use ExUnit.Case, async: true

  alias Jido.Action.Output
  alias Jido.{Exec, Flow, Instruction}
  alias Jido.Flow.{Choice, Dispatch, Iterate, Reduce, Ref, Step}
  alias Jido.Flow.Map, as: FlowMap

  defmodule PlainResult do
    use Jido.Action, name: "plain_effect_result"

    @impl true
    def run(params, _) do
      case Map.fetch(params, :effects) do
        {:ok, requests} -> {:ok, params.output, requests}
        :error -> {:ok, params.output}
      end
    end
  end

  test "maps and Output values accept an optional plain effect list" do
    flow =
      Flow.new!(
        name: "plain_result",
        components: [Step.new!(name: "value", action: PlainResult, params: Ref.input([]))],
        output: Ref.result("value")
      )

    for output <- [
          %{value: 1, effects: [:data]},
          Output.stream(1..2),
          Output.raw(:value),
          Output.batch([1, 2]),
          Output.opaque(make_ref())
        ],
        effects <- [:omitted, [], [:request, [:opaque, :list], :request]] do
      params =
        if effects == :omitted, do: %{output: output}, else: %{output: output, effects: effects}

      expected = if effects in [:omitted, []], do: {:ok, output}, else: {:ok, output, effects}

      assert Exec.run(PlainResult, params) == expected
      assert Exec.run(flow, params) == expected
      assert Exec.run(Instruction.new!(target: flow, params: params)) == expected
      assert_modes(flow, params, expected)
    end
  end

  test "a stream with plain effects stays lazy through direct, Flow, and async execution" do
    owner = self()
    ref = make_ref()

    stream =
      Stream.map([1, 2], fn item ->
        send(owner, {ref, :consumed, item})
        item
      end)

    output = Output.stream(stream, meta: %{source: :test})
    params = %{output: output, effects: [:request]}

    flow =
      Flow.new!(
        name: "stream_effects",
        components: [Step.new!(name: "value", action: PlainResult, params: Ref.input([]))],
        output: Ref.result("value")
      )

    expected = {:ok, output, [:request]}

    assert Exec.run(PlainResult, params) == expected
    assert Exec.run(flow, params) == expected
    assert Exec.await(Exec.run_async(flow, params)) == expected
    assert_modes(flow, params, expected)
    refute_received {^ref, :consumed, _}
    assert Enum.to_list(output.value) == [1, 2]
    assert_received {^ref, :consumed, 1}
    assert_received {^ref, :consumed, 2}
  end

  test "a later stream failure is separate from Action success and its effect list" do
    output = Output.stream(Stream.map([1], fn _ -> raise "consumer failure" end))

    flow =
      Flow.new!(
        name: "failing_stream",
        components: [Step.new!(name: "value", action: PlainResult, params: Ref.input([]))],
        output: Ref.result("value")
      )

    for target <- [PlainResult, flow] do
      assert {:ok, ^output, [:request]} = Exec.run(target, %{output: output, effects: [:request]})
      assert_raise RuntimeError, "consumer failure", fn -> Enum.to_list(output.value) end
    end
  end

  defmodule Request do
    use Jido.Action, name: "request_effect"

    @impl true
    def run(params, context) do
      if params[:gate] do
        send(context.owner, {context.ref, :ready, params.label, self()})

        receive do
          {ref, :release} when ref == context.ref -> :ok
        end
      end

      case params do
        %{fail: true} -> {:error, :rejected, [:must_not_escape]}
        %{legacy: extra} -> {:ok, %{label: params.label}, extra}
        %{malformed: items} -> {:ok, %{label: params.label}, items}
        _ -> {:ok, %{label: params.label}, Map.get(params, :effects, [params.label])}
      end
    end
  end

  defmodule InvalidOutput do
    use Jido.Action,
      name: "invalid_effect_output",
      output_schema: Zoi.object(%{label: Zoi.integer()})

    @impl true
    def run(_, _), do: {:ok, %{label: :bad}, [:must_not_escape]}
  end

  defmodule RawOutput do
    use Jido.Action, name: "raw_effect_output"
    @impl true
    def run(_, _), do: {:ok, Output.raw([1, 2]), [:raw]}
  end

  defmodule Next do
    use Jido.Action, name: "effect_continuation"
    @impl true
    def run(_, context), do: {:continue, %{label: :continued}, context.target}
  end

  defmodule Child do
    use Jido.Flow, name: "effect_child"

    flow do
      step "z_first", action: Request, params: %{label: :child_first}
      step "a_second", action: Request, params: %{label: :child_second}, needs: ["z_first"]
      output result("a_second")
    end
  end

  defmodule Nested do
    use Jido.Flow, name: "effect_nested"

    flow do
      step "child", action: Child, params: %{}
      step "after", action: Request, params: %{label: :after}, needs: ["child"]
      output result("after")
    end
  end

  test "a one-step Flow preserves the direct Action output and effects" do
    expected = {:ok, %{label: :submit}, [:submit]}
    assert Exec.run(Request, %{label: :submit}) == expected
    assert Exec.run(one(), %{label: :submit}) == expected
    assert Exec.run(Instruction.new!(target: one(), params: %{label: :submit})) == expected
    assert Exec.await(Exec.run_async(one(), %{label: :submit})) == expected
  end

  test "all three successful steps contribute effects in dependency order" do
    flow = three()
    expected = {:ok, %{label: :third}, [:first, :second, :third]}
    assert Exec.run(flow) == expected
    assert_modes(flow, %{}, expected)
  end

  test "parallel effects use canonical name order after reversed worker completion" do
    flow =
      Flow.new!(
        name: "parallel",
        components: [step("b", %{label: :b, gate: true}), step("a", %{label: :a, gate: true})],
        output: %{done: true}
      )

    result = reverse_workers(flow, [:a, :b])
    assert result == {:ok, %{done: true}, [:a, :b]}
  end

  test "nested Flows preserve every effect once, including unreferenced outputs" do
    expected = {:ok, %{label: :after}, [:child_first, :child_second, :after]}
    assert Exec.run(Nested) == expected
    assert_modes(Nested, %{}, expected)
  end

  test "duplicate requests and list-valued opaque requests keep their shape" do
    params = %{label: :value, effects: [[:a, :b], :same, :same]}
    expected = {:ok, %{label: :value}, params.effects}
    assert Exec.run(one(), params) == expected
    assert_modes(one(), params, expected)
  end

  test "Choice keeps only the selected option or fallback" do
    choice =
      Choice.new!(
        name: "choose",
        options: [
          Choice.Option.new!(
            name: "yes",
            condition: Ref.input(:choose),
            action: Request,
            params: %{label: :selected}
          )
        ],
        fallback: Choice.Fallback.new!(action: Request, params: %{label: :fallback})
      )

    flow = Flow.new!(name: "choice_effects", components: [choice], output: Ref.result("choose"))

    for {choose, label} <- [{true, :selected}, {false, :fallback}] do
      expected = {:ok, %{label: label}, [label]}
      assert Exec.run(flow, %{choose: choose}) == expected
      assert_modes(flow, %{choose: choose}, expected)
    end
  end

  test "Map effects use item order after reversed completion" do
    flow = mapped(%{label: Ref.item(), gate: true})

    assert reverse_workers(flow, [:a, :b]) ==
             {:ok, %{items: [%{label: :a}, %{label: :b}]}, [:a, :b]}

    expected = {:ok, %{items: [%{label: :a}, %{label: :b}]}, [:a, :b]}
    assert_modes(mapped(%{label: Ref.item()}), %{}, expected)
  end

  test "Map collect_errors keeps successful item effects and no failed item effects" do
    component =
      FlowMap.new!(
        name: "map",
        collection: [%{label: :a}, %{label: :b, fail: true}, %{label: :c}],
        action: Request,
        params: Ref.item(),
        on_error: :collect_errors
      )

    flow =
      Flow.new!(
        name: "collect_effects",
        components: [component],
        output: %{items: Ref.result("map")}
      )

    assert {:ok, %{items: [_, %{status: :error}, _]}, [:a, :c]} = Exec.run(flow)
    assert_modes(flow, %{}, Exec.run(flow))
  end

  test "Reduce preserves list-valued effects in serial item order" do
    component =
      Reduce.new!(
        name: "reduce",
        collection: [:a, :b],
        initial: %{},
        action: Request,
        params: %{label: Ref.item(), effects: [[Ref.item()]]}
      )

    flow =
      Flow.new!(name: "reduce_effects", components: [component], output: Ref.result("reduce"))

    expected = {:ok, %{label: :b}, [[:a], [:b]]}
    assert Exec.run(flow) == expected
    assert_modes(flow, %{}, expected)
  end

  test "Iterate preserves iteration order and zero iterations have no effects" do
    for count <- [0, 3] do
      flow = iterated(count)
      expected_effects = if count == 0, do: [], else: [0, 1, 2]
      result = Exec.run(flow)

      if count == 0 do
        assert {:ok, %{iterations: 0}} = result
      else
        assert {:ok, %{iterations: 3}, ^expected_effects} = result
      end

      assert_modes(flow, %{}, result)
    end
  end

  test "empty Map and Reduce return no effects" do
    for component <- [
          FlowMap.new!(name: "empty", collection: [], action: Request),
          Reduce.new!(name: "empty", collection: [], initial: %{}, action: Request)
        ] do
      flow =
        Flow.new!(
          name: "empty_effects",
          components: [component],
          output: %{value: Ref.result("empty")}
        )

      assert {:ok, _} = result = Exec.run(flow)
      assert_modes(flow, %{}, result)
    end
  end

  test "Dispatch collects prior, decision, normal expander, and continuation effects" do
    normal = dispatched(Request)
    expected = {:ok, %{label: :decision}, [:first, :decision, :decision]}
    assert Exec.run(normal) == expected

    for {target, output, tail} <- [
          {Request, %{label: :continued}, [:continued]},
          {Child, %{label: :child_second}, [:child_first, :child_second]}
        ] do
      expected = {:ok, output, [:first, :decision] ++ tail}
      assert Exec.run(dispatched(Next), %{}, %{target: target}) == expected
      assert Exec.await(Exec.run_async(dispatched(Next), %{}, %{target: target})) == expected
    end
  end

  defmodule BatchedNext do
    use Jido.Action, name: "batched_effect_next"
    @impl true
    def run(%{label: 0}, %{fail: true}), do: {:error, :rejected}
    def run(%{label: 0}, _), do: {:ok, %{done: true}, [[:terminal]]}

    def run(%{label: count}, context) do
      {:continue, %{label: count - 1, effects: [[count - 1], :same]}, context.flow}
    end
  end

  test "several continuations preserve effect batches and discard them on final failure" do
    flow =
      Flow.new!(
        name: "batched_effects",
        components: [
          Dispatch.new!(
            name: "next",
            decision: Request,
            expander: BatchedNext,
            params: Ref.input([])
          )
        ],
        output: Ref.result("next")
      )

    input = %{label: 4, effects: [[4], :same]}
    expected = {:ok, %{done: true}, Enum.flat_map(4..0//-1, &[[&1], :same]) ++ [[:terminal]]}

    for opts <- [[], [timeout: 5_000]] do
      assert Exec.run(flow, input, %{flow: flow}, opts) == expected
      assert {:error, _} = Exec.run(flow, input, %{flow: flow, fail: true}, opts)
    end

    assert Exec.await(Exec.run_async(flow, input, %{flow: flow})) == expected
  end

  defmodule Ancillary do
    use Jido.Action, name: "continued_ancillary"
    @impl true
    def run(_, _), do: {:ok, %{}, %{note: :ancillary}}
  end

  test "a continued Action rejects a third element that is not an effect list" do
    for target <- [Next, dispatched(Next)] do
      assert {:error, error} = Exec.run(target, %{}, %{target: Ancillary})
      assert error.details.reason == :invalid_effects
    end
  end

  test "collection failure and iteration exhaustion return no earlier effects" do
    for module <- [FlowMap, Reduce] do
      options = [
        name: "work",
        collection: [%{label: :first}, %{label: :bad, fail: true}],
        action: Request,
        params: Ref.item()
      ]

      options = if module == Reduce, do: Keyword.put(options, :initial, %{}), else: options

      flow =
        Flow.new!(
          name: "failed_collection",
          components: [module.new!(options)],
          output: %{result: Ref.result("work")}
        )

      assert {:error, _} = result = Exec.run(flow, %{}, %{}, max_concurrency: 1)
      assert_modes(flow, %{}, result)
    end

    flow = iterated(4)
    assert {:error, _} = result = Exec.run(flow)
    assert_modes(flow, %{}, result)
  end

  test "continuation failures return no effect batch" do
    for target <- [InvalidOutput, :invalid_target] do
      assert {:error, _} = Exec.run(dispatched(Next), %{}, %{target: target})
    end

    assert {:error, _} = Exec.run(dispatched(Next), %{}, %{target: Next}, max_continuations: 1)
  end

  test "malformed effect lists fail at the Action boundary in direct and Flow execution" do
    for effects <- [
          :bad,
          nil,
          %{},
          %{items: [:request]},
          [:a | :bad],
          Stream.map([1], fn _ -> raise "must not consume effects" end)
        ] do
      for target <- [Request, one()] do
        assert {:error, error} = Exec.run(target, %{label: :bad, malformed: effects})
        assert error.details.reason == :invalid_effects
        assert error.message =~ "proper list of effect requests"
        refute Jido.Action.Error.retryable?(error)
      end
    end
  end

  test "empty effect lists normalize to a two-element success" do
    for target <- [Request, one()] do
      assert Exec.run(target, %{label: :empty, effects: []}) == {:ok, %{label: :empty}}
    end
  end

  test "output envelopes remain output, separate from effects" do
    flow =
      Flow.new!(
        name: "raw",
        components: [Step.new!(name: "raw", action: RawOutput)],
        output: Ref.result("raw")
      )

    expected = {:ok, Output.raw([1, 2]), [:raw]}
    assert Exec.run(RawOutput) == expected
    assert Exec.run(flow) == expected
  end

  test "Action and Flow output validation never return executable effects on failure" do
    assert {:error, _} = Exec.run(InvalidOutput)
    flow = %{one() | output_schema: Zoi.object(%{label: Zoi.integer()})}
    assert {:error, _} = Exec.run(flow, %{label: :invalid})
    assert_modes(flow, %{label: :invalid}, Exec.run(flow, %{label: :invalid}))
    assert {:error, _} = Exec.run(Request, %{label: :bad, fail: true})
  end

  test "a later failure returns no partial effect batch in all execution modes" do
    flow =
      Flow.new!(
        name: "failed",
        components: [
          step("first", %{label: :first}),
          step("failed", %{label: :bad, fail: true}, ["first"])
        ],
        output: Ref.result("failed")
      )

    assert {:error, _} = result = Exec.run(flow)
    assert_modes(flow, %{}, result)
  end

  for mode <- [:cancel, :await_timeout, :call_timeout] do
    test "#{mode} removes pending effects and terminates active work" do
      ref = make_ref()

      flow =
        Flow.new!(
          name: "blocked",
          components: [
            step("first", %{label: :deferred}),
            step("block", %{label: :blocked, gate: true}, ["first"])
          ],
          output: Ref.result("block")
        )

      opts = if unquote(mode) == :call_timeout, do: [timeout: 1_000], else: []
      handle = Exec.run_async(flow, %{}, %{owner: self(), ref: ref}, opts)
      on_exit(fn -> if Process.alive?(handle.pid), do: Process.exit(handle.pid, :kill) end)
      assert_receive {^ref, :ready, :blocked, worker}, 1_000
      monitor = Process.monitor(worker)

      case unquote(mode) do
        :cancel -> assert :ok = Exec.cancel(handle)
        :await_timeout -> assert {:error, %Exec.Error.AsyncTimeoutError{}} = Exec.await(handle, 0)
        :call_timeout -> assert {:error, %Flow.Error.TimeoutError{}} = Exec.await(handle, 2_000)
      end

      assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 1_000
      refute_received {_, _, :result, {:ok, _, [_ | _]}}
    end
  end

  defp one do
    Flow.new!(
      name: "one",
      components: [step("request", Ref.input([]))],
      output: Ref.result("request")
    )
  end

  defp three do
    Flow.new!(
      name: "three",
      components: [
        step("z_first", %{label: :first}),
        step("a_second", %{label: :second}, ["z_first"]),
        step("b_third", %{label: :third}, ["a_second"])
      ],
      output: Ref.result("b_third")
    )
  end

  defp mapped(params) do
    Flow.new!(
      name: "map_effects",
      components: [
        FlowMap.new!(name: "map", collection: [:a, :b], action: Request, params: params)
      ],
      output: %{items: Ref.result("map")}
    )
  end

  defp iterated(count) do
    Flow.new!(
      name: "iterate_effects",
      components: [
        Iterate.new!(
          name: "loop",
          action: Request,
          params: %{label: Ref.iteration_index()},
          state: Iterate.State.new!(schema: Zoi.object(%{}), initial: %{}, update: %{}),
          completion: Jido.Expr.new!(:gte, [Ref.iteration_index(), count]),
          max_iterations: 3
        )
      ],
      output: Ref.result("loop")
    )
  end

  defp dispatched(expander) do
    Flow.new!(
      name: "dispatch_effects",
      components: [
        step("first", %{label: :first}),
        Dispatch.new!(
          name: "dispatch",
          decision: Request,
          expander: expander,
          params: %{label: :decision},
          needs: ["first"]
        )
      ],
      output: Ref.result("dispatch")
    )
  end

  defp step(name, params, needs \\ []) do
    Step.new!(name: name, action: Request, params: params, needs: needs)
  end

  defp assert_modes(flow, input, expected) do
    for mode <- [:step, :wave, :continue] do
      assert {:ok, execution} = Exec.start(flow, input)
      actual = finish(execution, mode)

      case expected do
        {:error, error} ->
          assert {:error, actual_error} = actual
          assert actual_error.__struct__ == error.__struct__
          assert actual_error.message == error.message
          assert actual_error.details == error.details

        _ ->
          assert actual == expected
      end
    end
  end

  defp finish(execution, mode) do
    if Exec.status(execution) == :running do
      next =
        case mode do
          :continue ->
            {:ok, next} = Exec.continue(execution)
            next

          _ ->
            # Select the last ready unit to prove that effects do not use step order.
            result =
              if mode == :step,
                do: Exec.step(execution, List.last(Exec.ready(execution)).token),
                else: Exec.wave(execution)

            {:ok, _, next} = result
            next
        end

      finish(next, mode)
    else
      Exec.result(execution)
    end
  end

  defp reverse_workers(flow, labels) do
    ref = make_ref()
    handle = Exec.run_async(flow, %{}, %{owner: self(), ref: ref})

    try do
      workers =
        for label <- labels, into: %{} do
          assert_receive {^ref, :ready, ^label, worker}, 1_000
          {label, worker}
        end

      for label <- Enum.reverse(labels) do
        worker = workers[label]
        monitor = Process.monitor(worker)
        send(worker, {ref, :release})
        assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 1_000
      end

      Exec.await(handle)
    after
      Exec.cancel(handle)
    end
  end
end
