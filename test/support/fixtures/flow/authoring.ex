defmodule JidoActionTest.Fixtures.FlowAuthoring do
  @moduledoc false

  alias Jido.Flow
  alias Jido.Flow.{Builder, Choice, Condition, Iterate, Reduce, Ref, Step, Subflow}
  alias Jido.Flow.Map, as: FlowMap
  alias JidoActionTest.Fixtures.NestedFlow
  alias JidoActionTest.Fixtures.Actions.{Add, Multiply}

  def math_builder do
    Builder.new(
      name: "math_flow",
      description: "Adds one and doubles the result"
    )
    |> Builder.step(
      "add_one",
      Add,
      %{value: Builder.input(:value), amount: Builder.value(1)}
    )
    |> Builder.step(
      "double",
      Multiply,
      %{value: Builder.result("add_one", :value), amount: Builder.value(2)}
    )
    |> Builder.output(Builder.result("double"))
  end

  def math_flow! do
    {:ok, flow} = Builder.build(math_builder())
    flow
  end

  def mixed_flow! do
    Flow.new!(
      name: "canonical_mixed_flow",
      description: "All canonical authoring forms",
      components: [
        Step.new!(
          name: "load",
          action: Add,
          params: %{value: Ref.input(:value), amount: 1},
          meta: %{owner: "parity"}
        ),
        Subflow.new!(
          name: "child",
          flow: NestedFlow,
          params: %{value: Ref.result("load", :value)},
          after: ["load"]
        ),
        Choice.new!(
          name: "route",
          options: [
            Choice.Option.new!(
              name: "add",
              condition: Condition.eq(Ref.input(:kind), :add),
              action: Add,
              params: %{value: Ref.result("child", :value), amount: 1}
            )
          ],
          fallback:
            Choice.Fallback.new!(
              action: Multiply,
              params: %{value: Ref.result("child", :value), amount: 2}
            )
        ),
        FlowMap.new!(
          name: "mapped",
          collection: Ref.input(:items),
          action: Add,
          params: %{value: Ref.item(:value), amount: 1},
          on_error: :collect_errors
        ),
        Reduce.new!(
          name: "reduced",
          collection: Ref.result("mapped"),
          initial: %{value: 1},
          action: Multiply,
          params: %{value: Ref.accumulator(:value), amount: Ref.item(:value)}
        ),
        Iterate.new!(
          name: "loop",
          action: Add,
          params: %{value: Ref.state(:count), amount: 1},
          state:
            Iterate.State.new!(
              schema: [],
              initial: %{count: 0},
              update: %{count: Ref.body_result(:value)}
            ),
          completion: Condition.gte(Ref.iteration_index(), 2),
          max_iterations: 2
        )
      ],
      output: Ref.result("loop")
    )
  end

  def mixed_builder do
    Builder.new(
      name: "canonical_mixed_flow",
      description: "All canonical authoring forms"
    )
    |> Builder.step(
      "load",
      Add,
      %{value: Builder.input(:value), amount: 1},
      meta: %{owner: "parity"}
    )
    |> Builder.step(
      "child",
      NestedFlow,
      %{value: Builder.result("load", :value)},
      after: ["load"]
    )
    |> Builder.choice(
      "route",
      [
        Builder.option(
          "add",
          Builder.eq(Builder.input(:kind), :add),
          Add,
          %{value: Builder.result("child", :value), amount: 1}
        )
      ],
      Builder.fallback(
        Multiply,
        %{value: Builder.result("child", :value), amount: 2}
      )
    )
    |> Builder.map(
      "mapped",
      Builder.input(:items),
      Add,
      %{value: Builder.item(:value), amount: 1},
      on_error: :collect_errors
    )
    |> Builder.reduce(
      "reduced",
      Builder.result("mapped"),
      %{value: 1},
      Multiply,
      %{value: Builder.accumulator(:value), amount: Builder.item(:value)}
    )
    |> Builder.iterate(
      "loop",
      Add,
      %{value: Builder.state(:count), amount: 1},
      %{
        schema: [],
        initial: %{count: 0},
        update: %{count: Builder.body_result(:value)}
      },
      completion: Builder.gte(Builder.iteration_index(), 2),
      max_iterations: 2
    )
    |> Builder.output(Builder.result("loop"))
  end
end
