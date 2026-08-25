defmodule Jido.Flow.DSL.FlowTest.MixedFlow do
  @moduledoc false

  use Jido.Flow, name: "mixed_dsl"

  flow do
    step("load",
      action: JidoActionTest.TestActions.Add,
      params: %{value: input(:value), amount: 1},
      meta: %{owner: "dsl"}
    )

    choice "route" do
      option "add" do
        condition(input(:kind) == :add)
        action(JidoActionTest.TestActions.Add)
        params(%{value: result("load", :value), amount: 1})
      end

      otherwise(
        action: JidoActionTest.TestActions.Multiply,
        params: %{value: result("load", :value), amount: 1}
      )
    end

    map("mapped",
      collection: input(:items),
      action: JidoActionTest.TestActions.Add,
      params: %{value: item(:value), amount: 1},
      on_error: :collect_errors
    )

    reduce "reduced" do
      collection(result("mapped"))
      initial(%{value: 1})
      action(JidoActionTest.TestActions.Multiply)
      params(%{value: accumulator(:value), amount: item(:value)})
    end

    iterate "loop" do
      state([], initial: %{count: 0})
      action(JidoActionTest.TestActions.Add)
      params(%{value: state(:count), amount: 1})
      update(%{count: body_result(:value)})
      repeat(1)
    end

    output(result("loop"))
  end
end

defmodule Jido.Flow.DSL.FlowTest do
  use ExUnit.Case, async: true

  alias Jido.Flow.Choice
  alias Jido.Flow.Iterate
  alias Jido.Flow.Map, as: FlowMap
  alias Jido.Flow.Reduce
  alias Jido.Flow.Ref
  alias Jido.Flow.Step

  test "the unchanged Spark forms lower directly to canonical records" do
    flow = Jido.Flow.DSL.FlowTest.MixedFlow.flow()

    assert [
             %Step{name: "load", params: %{amount: 1}, meta: %{owner: "dsl"}},
             %Choice{name: "route", after: []},
             %FlowMap{name: "mapped", on_error: :collect_errors},
             %Reduce{name: "reduced"},
             %Iterate{name: "loop", max_iterations: 1}
           ] = flow.components

    assert flow.output == Ref.result("loop")
  end

  test "Flow output is required" do
    code = """
    defmodule MissingOutputFlow do
      use Jido.Flow, name: "missing_output"

      flow do
        step "add", action: JidoActionTest.TestActions.Add, params: %{value: 1}
      end
    end
    """

    assert_raise CompileError, ~r/Flow output is required/, fn -> Code.compile_string(code) end
  end

  test "a Flow module in a Choice Action slot is a source-aware compile error" do
    code = """
    defmodule NestedChoiceTargetFlow do
      use Jido.Flow, name: "nested_choice_target"

      flow do
        choice "route" do
          option "nested" do
            condition(1 == 1)
            action(JidoActionTest.FlowFixtures.NestedFlow)
            params(%{value: 1})
          end

          otherwise action: JidoActionTest.TestActions.Add, params: %{value: 1}
        end

        output(result("route"))
      end
    end
    """

    error =
      assert_raise CompileError, ~r/wrong executable kind/, fn -> Code.compile_string(code) end

    assert error.line == 6
  end
end
