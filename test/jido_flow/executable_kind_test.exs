defmodule Jido.Flow.ExecutableKindTest do
  use ExUnit.Case, async: true

  alias Jido.Flow
  alias Jido.Flow.Error.InvalidDefinitionError
  alias Jido.Flow.Choice
  alias Jido.Flow.Condition
  alias Jido.Flow.Iterate
  alias Jido.Flow.Map, as: FlowMap
  alias Jido.Flow.Reduce
  alias Jido.Flow.Ref
  alias JidoActionTest.Fixtures.NestedFlow

  test "embedded Action slots reject a Flow module" do
    components = [
      Choice.new!(
        name: "choice",
        options: [
          Choice.Option.new!(
            name: "nested",
            condition: Condition.eq(1, 1),
            action: NestedFlow
          )
        ],
        fallback: Choice.Fallback.new!(action: JidoActionTest.Fixtures.Actions.Add)
      ),
      FlowMap.new!(name: "map", collection: [], action: NestedFlow),
      Reduce.new!(name: "reduce", collection: [], initial: %{}, action: NestedFlow),
      Iterate.new!(
        name: "iterate",
        action: NestedFlow,
        state: Iterate.State.new!(schema: [], initial: %{}, update: %{}),
        completion: Condition.eq(Ref.iteration_index(), 0),
        max_iterations: 1
      )
    ]

    Enum.each(components, fn component ->
      flow =
        Flow.new!(
          name: "bad_#{component.name}",
          components: [component],
          output: Ref.result(component.name)
        )

      assert {:error, %InvalidDefinitionError{details: details}} =
               Flow.validate_executable(flow)

      assert details.component == component.name
      assert details.actual == :flow
      assert details.expected == :action
    end)
  end
end
