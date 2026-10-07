Code.require_file("../support/runtime.exs", __DIR__)

defmodule JidoActionTest.Property.Flow.ComponentContractTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  @moduletag :property
  alias Jido.{Exec, Expr, Flow}
  alias Jido.Flow.Ref
  alias JidoActionTest.Property.Runtime
  alias Runtime.Emit

  defmodule Fold do
    use Jido.Action, name: "property_fold"
    @impl true
    def run(%{acc: acc, item: item}, context) do
      send(context.observer, {context.token, :call, item, self()})
      {:ok, %{value: acc * 3 - item}, [item]}
    end
  end

  defmodule Child do
    use Jido.Flow, name: "property_child"

    flow do
      step "echo",
        action: JidoActionTest.Property.Runtime.Emit,
        params: %{value: input(:value)}

      output result("echo")
    end
  end

  @tag contracts: ["EXEC-003", "EFFECT-001"]
  @tag contract_cases: [
         "EXEC-003/map",
         "EXEC-003/reduce",
         "EXEC-003/empty",
         "EXEC-003/duplicates",
         "EFFECT-001/item-order"
       ]
  property "Map and Reduce match independent list models including empty and duplicate input" do
    check all(
            values <- list_of(integer(-5..5), max_length: 5),
            seed <- integer(-5..5),
            max_runs: 25
          ) do
      for items <- [[], [seed], [seed, seed], values] do
        mapped =
          JidoActionTest.FlowComponent.map!(
            name: "work",
            collection: items,
            action: Emit,
            params: %{value: Expr.new!(:*, [Ref.item(), 2]), label: Ref.item()}
          )

        reduced =
          JidoActionTest.FlowComponent.reduce!(
            name: "work",
            collection: items,
            initial: %{value: seed},
            action: Fold,
            params: %{acc: Ref.accumulator(:value), item: Ref.item()}
          )

        expected_map = %{items: Enum.map(items, &%{value: &1 * 2})}
        expected_fold = %{value: Enum.reduce(items, seed, &(&2 * 3 - &1))}

        for {component, output, expected} <- [
              {mapped, %{items: Ref.result("work")}, expected_map},
              {reduced, Ref.result("work"), expected_fold}
            ] do
          flow =
            JidoActionTest.FlowBuilder.new!(
              name: "collection",
              components: [component],
              output: output
            )

          assert_modes(flow, expected, items, items, component.kind == :reduce)
        end
      end
    end
  end

  @tag contracts: ["EXEC-003", "EFFECT-001", "EFFECT-002"]
  @tag contract_cases: [
         "EXEC-003/choice-first",
         "EXEC-003/choice-second",
         "EXEC-003/choice-fallback",
         "EFFECT-002/choice-failure"
       ]
  property "Choice uses the first match and never falls back after selected work fails" do
    check all(value <- integer(-50..50), max_runs: 25) do
      for {first, second, selected} <- [
            {true, true, "first"},
            {false, true, "second"},
            {false, false, "fallback"}
          ],
          fail <- [false, true] do
        choice =
          JidoActionTest.FlowComponent.choice!(
            name: "work",
            options: [
              JidoActionTest.FlowComponent.option!(
                name: "first",
                condition: first,
                action: Emit,
                params: %{value: value, label: "first", fail: fail}
              ),
              JidoActionTest.FlowComponent.option!(
                name: "second",
                condition: second,
                action: Emit,
                params: %{value: value, label: "second", fail: fail}
              )
            ],
            fallback:
              JidoActionTest.FlowComponent.fallback!(
                action: Emit,
                params: %{value: value, label: "fallback", fail: fail}
              )
          )

        flow =
          JidoActionTest.FlowBuilder.new!(
            name: "choice",
            components: [choice],
            output: Ref.result("work")
          )

        if fail do
          for mode <- [:run, :step, :wave, :continue] do
            Runtime.with_context(fn context ->
              assert {:error, %Jido.Action.Error.ExecutionFailureError{details: details}} =
                       execute(flow, context, mode)

              assert details.reason == {:rejected, value}
              Runtime.assert_calls(context, [selected])
            end)
          end
        else
          assert_modes(flow, %{value: value}, [selected], [selected], true)
        end
      end
    end
  end

  @tag contracts: ["EXEC-003", "EFFECT-001", "EFFECT-002"]
  @tag contract_cases: [
         "EXEC-003/iterate-zero",
         "EXEC-003/iterate-replacements",
         "EXEC-003/iterate-bound",
         "EFFECT-002/exhaustion"
       ]
  property "Iterate commits serial replacements and stops at completion or the bound" do
    check all(seed <- integer(-5..5), count <- integer(1..5), max_runs: 25) do
      for iterations <- [0, count] do
        loop = iterator(seed, iterations, count)
        values = if iterations == 0, do: [], else: Enum.to_list(0..(iterations - 1))
        final = Enum.reduce(values, seed, fn item, acc -> acc * 3 - item end)
        latest = if iterations == 0, do: nil, else: %{value: final}

        expected = %{
          kind: :jido_flow_iterate_result,
          iterations: iterations,
          state: %{value: final},
          output: latest
        }

        assert_modes(loop, expected, values, values, true)
      end

      exhausted = iterator(seed, count + 1, count)

      for mode <- [:run, :step, :wave, :continue] do
        Runtime.with_context(fn context ->
          assert {:error, %Flow.Error.ExecutionFailureError{details: details}} =
                   execute(exhausted, context, mode)

          assert details.phase == :iterate_exhaustion
          assert details.completed_iterations == count
          Runtime.assert_calls(context, Enum.to_list(0..(count - 1)))
        end)
      end
    end
  end

  @tag contracts: ["EXEC-003", "EFFECT-001"]
  @tag contract_cases: ["EXEC-003/subflow", "EFFECT-001/nested"]
  property "Subflow input mapping and output agree across all step-wise modes" do
    check all(value <- integer(), max_runs: 40) do
      flow =
        JidoActionTest.FlowBuilder.new!(
          name: "parent",
          components: [
            JidoActionTest.FlowComponent.subflow!(
              name: "child",
              flow: Child,
              params: %{value: value}
            )
          ],
          output: %{child: Ref.result("child")}
        )

      assert_modes(flow, %{child: %{value: value}}, [value], [value], true)
    end
  end

  defp iterator(seed, target, maximum) do
    loop =
      JidoActionTest.FlowComponent.iterate!(
        name: "loop",
        action: Fold,
        params: %{acc: Ref.state(:value), item: Ref.iteration_index()},
        state:
          JidoActionTest.FlowComponent.state!(
            schema: Zoi.object(%{value: Zoi.integer()}),
            initial: %{value: seed},
            update: %{value: Ref.body_result(:value)}
          ),
        completion: Expr.new!(:>=, [Ref.iteration_index(), target]),
        max_iterations: maximum
      )

    JidoActionTest.FlowBuilder.new!(
      name: "iterate",
      components: [loop],
      output: Ref.result("loop")
    )
  end

  defp assert_modes(flow, output, effects, calls, serial?) do
    expected = if effects == [], do: {:ok, output}, else: {:ok, output, effects}

    for mode <- [:run, :concurrent, :step, :wave, :continue] do
      Runtime.with_context(fn context ->
        assert execute(flow, context, mode) == expected
        observed = Runtime.calls(context)
        values = Enum.map(observed, &elem(&1, 0))
        assert Enum.sort(values) == Enum.sort(calls)
        if serial?, do: assert(values == calls)
        Runtime.assert_workers_stopped(Enum.map(observed, &elem(&1, 1)))
      end)
    end
  end

  defp execute(flow, context, mode) when mode in [:run, :concurrent] do
    Exec.run(flow, %{}, context, Runtime.options(context, if(mode == :run, do: 1, else: 3)))
  end

  defp execute(flow, context, mode) do
    {:ok, execution} = Exec.start(flow, %{}, context, Runtime.options(context))
    Runtime.finish(execution, mode)
  end
end
