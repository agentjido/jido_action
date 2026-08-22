defmodule Jido.Flow.IteratorNamingTest do
  use ExUnit.Case, async: true

  alias Jido.Flow.Condition
  alias Jido.Flow.Iterator
  alias Jido.Flow.Ref
  alias JidoTest.TestActions.Add

  test "uses Iterator names throughout the canonical node and stored data" do
    iterator =
      Iterator.new!(
        name: :count,
        action: Add,
        input: %{count: Ref.state(:count)},
        state: [schema: [], initial: %{count: 0}, update: Ref.body_result()],
        completion: %Condition{operator: :gte, operands: [Ref.state(:count), Ref.value(3)]},
        max_iterations: 3
      )

    assert %Iterator{} = iterator
    assert %{kind: :iterate, state: %{kind: :iterate_state}} = Iterator.to_map(iterator)
  end
end
