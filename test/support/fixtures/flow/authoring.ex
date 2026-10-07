defmodule JidoActionTest.Fixtures.FlowAuthoring do
  @moduledoc false
  alias Jido.Flow
  alias Jido.Flow.{Choice, Iterate, Reduce, Ref, Step, Subflow}
  alias Jido.Flow.Map, as: FlowMap
  alias JidoActionTest.Fixtures.NestedFlow
  alias JidoActionTest.Fixtures.Actions.{Add, Multiply}

  def math_data do
    %{
      output: Jido.Flow.Ref.result("double"),
      components: [
        %{
          kind: :step,
          name: "add_one",
          action: Add,
          params: %{value: Jido.Flow.Ref.input(:value), amount: 1}
        },
        %{
          kind: :step,
          name: "double",
          action: Multiply,
          params: %{value: Jido.Flow.Ref.result("add_one", :value), amount: 2}
        }
      ],
      name: "math_flow",
      description: "Adds one and doubles the result"
    }
  end

  def math_flow! do
    {:ok, flow} = Jido.Flow.new(math_data())
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
          needs: ["load"]
        ),
        Choice.new!(
          name: "route",
          options: [
            Choice.Option.new!(
              name: "add",
              condition: Jido.Expr.new!(:==, [Ref.input(:kind), :add]),
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
          completion: Jido.Expr.new!(:>=, [Ref.iteration_index(), 2]),
          max_iterations: 2
        )
      ],
      output: Ref.result("loop")
    )
  end

  def mixed_data do
    %{
      output: Jido.Flow.Ref.result("loop"),
      components: [
        %{
          kind: :step,
          name: "load",
          action: Add,
          params: %{value: Jido.Flow.Ref.input(:value), amount: 1},
          meta: %{owner: "parity"}
        },
        %{
          kind: :subflow,
          flow: NestedFlow,
          name: "child",
          params: %{value: Jido.Flow.Ref.result("load", :value)},
          needs: ["load"]
        },
        %{
          kind: :choice,
          name: "route",
          options: [
            %{
              name: "add",
              condition: Jido.Expr.new!(:==, [Jido.Flow.Ref.input(:kind), :add]),
              action: Add,
              params: %{value: Jido.Flow.Ref.result("child", :value), amount: 1}
            }
          ],
          fallback: %{
            action: Multiply,
            params: %{value: Jido.Flow.Ref.result("child", :value), amount: 2}
          }
        },
        %{
          kind: :map,
          name: "mapped",
          collection: Jido.Flow.Ref.input(:items),
          action: Add,
          params: %{value: Jido.Flow.Ref.item(:value), amount: 1},
          on_error: :collect_errors
        },
        %{
          kind: :reduce,
          name: "reduced",
          collection: Jido.Flow.Ref.result("mapped"),
          initial: %{value: 1},
          action: Multiply,
          params: %{value: Jido.Flow.Ref.accumulator(:value), amount: Jido.Flow.Ref.item(:value)}
        },
        %{
          kind: :iterate,
          name: "loop",
          action: Add,
          params: %{value: Jido.Flow.Ref.state(:count), amount: 1},
          state: %{
            schema: [],
            initial: %{count: 0},
            update: %{count: Jido.Flow.Ref.body_result(:value)}
          },
          completion: Jido.Expr.new!(:>=, [Jido.Flow.Ref.iteration_index(), 2]),
          max_iterations: 2
        }
      ],
      name: "canonical_mixed_flow",
      description: "All canonical authoring forms"
    }
  end
end
