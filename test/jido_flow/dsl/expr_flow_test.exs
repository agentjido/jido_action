defmodule JidoActionTest.Flow.DSL.ExprFlowTest do
  use ExUnit.Case, async: true

  alias Jido.Expr
  alias Jido.Flow
  alias Jido.Flow.{Builder, Codec, Condition, Ref, Step}
  alias JidoActionTest.Fixtures.Actions.EchoParamsAction

  defmodule Parity do
    use Jido.Flow, name: "calculated"

    flow do
      step "load", action: EchoParamsAction, params: %{quantity: input(:quantity) + 1}

      output %{
        total: result("load", :quantity) * input(:price),
        label: context(:prefix) <> input(:name)
      }
    end
  end

  defmodule Child do
    use Jido.Flow, name: "expression_child"

    flow do
      step "echo", action: EchoParamsAction, params: %{value: input(:value) * 2}
      output result("echo")
    end
  end

  defmodule Mixed do
    use Jido.Flow, name: "expression_positions"

    flow do
      map "mapped",
        collection: [input(:start) + 1, 2],
        action: EchoParamsAction,
        params: %{value: item() * 2, index: item_index() + 1, id: "item-" <> item_id()}

      reduce "reduced",
        collection: result("mapped"),
        initial: %{value: input(:start) - 1},
        action: EchoParamsAction,
        params: %{value: accumulator(:value) + item(:value)}

      iterate "loop" do
        state [], initial: %{count: input(:start) - 1, done: false}
        action EchoParamsAction
        params %{count: state(:count) + 1, index: iteration_index() + 1}
        update %{count: body_result(:count), done: body_result(:count) >= 3}
        while not state(:done)
        max_iterations 5
      end

      step "inline", total <- result("reduced", :value) + 1 do
        {:ok, %{value: total}}
      end

      step "child", action: Child, params: %{value: result("inline", :value) + 1}

      choice "route" do
        option "enabled",
          condition: input(:enabled) and not context(:paused),
          action: EchoParamsAction,
          params: %{value: result("child", :value) / 2}

        otherwise action: EchoParamsAction, params: %{value: -input(:start)}
      end

      output %{
        value: result("route", :value),
        loop: result("loop", :state),
        eligible: expr(input(:enabled) and result("inline", :value) >= 9)
      }
    end
  end

  defmodule Dispatched do
    use Jido.Flow, name: "expression_dispatch"

    flow do
      dispatch "finish",
        decision: EchoParamsAction,
        expander: EchoParamsAction,
        params: %{value: min(input(:value) + 1, 10)}

      output result("finish")
    end
  end

  test "module DSL equals runtime authoring with shared helper syntax" do
    import Jido.Expr, only: [expr: 1]
    quantity = Ref.input(:quantity)
    load = Ref.result("load", :quantity)
    price = Ref.input(:price)
    prefix = Ref.context(:prefix)
    name = Ref.input(:name)
    params = %{quantity: expr(^quantity + 1)}
    output = %{total: expr(^load * ^price), label: expr(^prefix <> ^name)}

    assert {:ok, built} =
             Builder.new(name: "calculated")
             |> Builder.step("load", EchoParamsAction, params)
             |> Builder.output(output)
             |> Builder.build()

    direct =
      Flow.new!(
        name: "calculated",
        components: [Step.new!(name: "load", action: EchoParamsAction, params: params)],
        output: output
      )

    assert Parity.flow() == built
    assert direct == built
    assert {:ok, document, registry} = Codec.encode(built)
    assert {:ok, restored} = Codec.decode(JSON.decode!(JSON.encode!(document)), registry)
    assert restored == built
  end

  test "expressions work through every local scope, inline binding, child, and Choice" do
    assert {:ok, document, registry} = Codec.encode(Mixed.flow())
    assert {:ok, restored} = Codec.decode(JSON.decode!(JSON.encode!(document)), registry)

    for flow <- [Mixed, restored] do
      assert Jido.Exec.run(flow, %{start: 1, enabled: true}, %{paused: false}) ==
               {:ok, %{value: 10.0, loop: %{count: 3, done: true}, eligible: true}}

      assert {:ok, execution} =
               Jido.Exec.start(flow, %{start: 1, enabled: true}, %{paused: false})

      assert {:ok, execution} = Jido.Exec.continue(execution)

      assert Jido.Exec.result(execution) ==
               {:ok, %{value: 10.0, loop: %{count: 3, done: true}, eligible: true}}
    end

    assert Jido.Exec.run(Dispatched, %{value: 20}) == {:ok, %{value: 10}}
  end

  test "old Condition constructors can supply calculated parameter values" do
    step =
      Step.new!(
        name: "echo",
        action: EchoParamsAction,
        params: %{eligible: Condition.gte(Expr.new!(:multiply, [Ref.input(:score), 2]), 80)}
      )

    flow = Flow.new!(name: "condition_value", components: [step], output: Ref.result("echo"))
    assert Jido.Exec.run(flow, %{score: 40}) == {:ok, %{eligible: true}}
  end
end
