Code.require_file("../support/runtime.exs", __DIR__)
Code.require_file("../support/fuzz.exs", __DIR__)

defmodule JidoActionTest.Property.Flow.MixedContractTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Jido.{Exec, Expr}
  alias Jido.Flow.Ref
  alias JidoActionTest.Property.{Fuzz, Runtime}

  defmodule Fold do
    use Jido.Action, name: "property_mixed_fold"
    @impl true
    def run(%{acc: acc, item: item}, context) do
      send(context.observer, {context.token, :call, item, self()})
      {:ok, %{value: acc * 3 - item}, [item]}
    end
  end

  defmodule Child do
    use Jido.Flow, name: "property_mixed_child"

    flow do
      map "mapped",
        collection: input(:items),
        action: JidoActionTest.Property.Runtime.Emit,
        params: %{value: item() * input(:scale) + input(:offset), label: item()}

      output %{items: result("mapped")}
    end
  end

  for {suite, runs, maximum, budget} <- [{:property, 30, 5, 10_000}, {:fuzz, 300, 10, 300_000}] do
    @tag [
      {suite, true},
      max_runs: runs,
      max_run_time: budget,
      max_items: maximum,
      timeout: if(suite == :fuzz, do: 900_000, else: 90_000)
    ]
    @tag contracts: ["EXEC-003", "EFFECT-001"]
    @tag contract_cases: [
           "EXEC-003/mixed-empty",
           "EXEC-003/mixed-nested",
           "EFFECT-001/mixed-order"
         ]
    test "#{suite}: Choice, Map, Reduce and optional Subflow agree with a plain list model",
         context do
      generator =
        fixed_map(%{
          "items" => list_of(integer(-8..8), max_length: context.max_items),
          "seed" => integer(-8..8),
          "scale" => integer(-3..3),
          "offset" => integer(-8..8),
          "first" => boolean(),
          "nested" => boolean()
        })

      examples = [
        %{
          "items" => [],
          "seed" => 2,
          "scale" => -1,
          "offset" => 3,
          "first" => false,
          "nested" => false
        },
        %{
          "items" => [2, 2, -1],
          "seed" => -3,
          "scale" => 2,
          "offset" => 1,
          "first" => true,
          "nested" => true
        }
      ]

      Fuzz.check(
        "mixed_components",
        generator,
        Map.to_list(context) ++ [examples: examples],
        &assert_mixed/1
      )
    end
  end

  defp assert_mixed(sample) do
    items = sample["items"]
    offset = if sample["first"], do: sample["offset"], else: -sample["offset"]
    mapped = Enum.map(items, &(&1 * sample["scale"] + offset))
    expected = %{value: Enum.reduce(mapped, sample["seed"], &(&2 * 3 - &1))}
    effects = [offset] ++ items ++ mapped

    choice =
      JidoActionTest.FlowComponent.choice!(
        name: "choice",
        options: [
          JidoActionTest.FlowComponent.option!(
            name: "first",
            condition: sample["first"],
            action: Runtime.Emit,
            params: %{value: sample["offset"]}
          )
        ],
        fallback:
          JidoActionTest.FlowComponent.fallback!(
            action: Runtime.Emit,
            params: %{value: -sample["offset"]}
          )
      )

    {mapped_component, collection} = mapping(sample)

    reduced =
      JidoActionTest.FlowComponent.reduce!(
        name: "fold",
        collection: collection,
        initial: %{value: sample["seed"]},
        action: Fold,
        params: %{acc: Ref.accumulator(:value), item: Ref.item(:value)}
      )

    flow =
      JidoActionTest.FlowBuilder.new!(
        name: "mixed",
        components: [reduced, mapped_component, choice],
        output: Ref.result("fold")
      )

    for mode <- [:serial, :concurrent, :step, :wave, :continue] do
      Runtime.with_context(fn context ->
        assert execute(flow, context, mode) == {:ok, expected, effects}
        calls = Runtime.calls(context)
        # Map callbacks may start in any order. Effects must retain item order.
        assert Enum.sort(Enum.map(calls, &elem(&1, 0))) == Enum.sort(effects)
        Runtime.assert_workers_stopped(Enum.map(calls, &elem(&1, 1)))
      end)
    end

    [
      if(sample["nested"], do: "nested", else: "direct"),
      if(sample["first"], do: "first", else: "fallback"),
      "items:#{length(items)}",
      if(length(Enum.uniq(items)) < length(items), do: "duplicates", else: "unique")
    ]
  end

  defp mapping(%{"nested" => true} = sample) do
    {JidoActionTest.FlowComponent.subflow!(
       name: "map",
       flow: Child,
       params: %{
         items: sample["items"],
         scale: sample["scale"],
         offset: Ref.result("choice", :value)
       }
     ), Ref.result("map", :items)}
  end

  defp mapping(sample) do
    {JidoActionTest.FlowComponent.map!(
       name: "map",
       collection: sample["items"],
       action: Runtime.Emit,
       params: %{
         value:
           Expr.new!(:+, [
             Expr.new!(:*, [Ref.item(), sample["scale"]]),
             Ref.result("choice", :value)
           ]),
         label: Ref.item()
       }
     ), Ref.result("map")}
  end

  defp execute(flow, context, mode) when mode in [:serial, :concurrent] do
    Exec.run(flow, %{}, context, Runtime.options(context, if(mode == :serial, do: 1, else: 3)))
  end

  defp execute(flow, context, mode) do
    {:ok, execution} = Exec.start(flow, %{}, context, Runtime.options(context))
    Runtime.finish(execution, mode)
  end
end
