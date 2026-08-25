defmodule JidoActionTest.Flow.ElementTest do
  use ExUnit.Case, async: true

  alias Jido.Flow.{Choice, Condition, Element, Iterator, Node, Reduce, Ref}
  alias Jido.Flow.Map, as: FlowMap
  alias JidoActionTest.TestActions.Add

  test "constructs every tagged map and keyword element form" do
    state = %{schema: [], initial: %{}, update: Ref.body_result()}

    specs = [
      %{kind: :map, name: "map", collection: [], action: Add, input: Ref.item()},
      %{kind: :reduce, name: "reduce", collection: [], initial: %{}, action: Add},
      %{
        kind: :iterate,
        name: "iterate",
        action: Add,
        state: state,
        completion: %Condition{
          operator: :gte,
          operands: [Ref.iteration_index(), Ref.value(1)]
        },
        max_iterations: 1
      }
    ]

    for spec <- specs do
      assert {:ok, element_from_map} = Element.new(spec)
      assert {:ok, element_from_keyword} = Element.new(Map.to_list(spec))
      assert element_from_map == element_from_keyword
    end

    assert {:ok, %FlowMap{}} = Element.new(List.first(specs))
    assert {:ok, %Reduce{}} = Element.new(Enum.at(specs, 1))
    assert {:ok, %Iterator{}} = Element.new(List.last(specs))
  end

  test "infers untagged Step and Choice data" do
    option = [name: "yes", condition: Condition.eq(1, 1), action: Add]
    choice = [name: "choice", options: [option], fallback: [action: Add]]
    step = [name: "step", action: Add]

    assert {:ok, %Choice{}} = Element.new(Map.new(choice))
    assert {:ok, %Choice{}} = Element.new(choice)
    assert {:ok, %Node{}} = Element.new(Map.new(step))
    assert {:ok, %Node{}} = Element.new(step)

    assert {:error, _error} = Element.new([{:name, "bad"} | :tail])
    assert {:error, _error} = Element.new(:bad)
  end
end
