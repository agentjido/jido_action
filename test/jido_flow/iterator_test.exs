defmodule Jido.Flow.IteratorTest do
  use ExUnit.Case, async: true

  alias Jido.Action.Error.InvalidInputError
  alias Jido.Flow.{Condition, Iterator, Ref, State}
  alias JidoTest.TestActions.Add

  test "builds a bounded Iterator with explicit State" do
    iterator = iterator()

    assert iterator.name == "count"
    assert iterator.action == Add
    assert iterator.max_iterations == 5
    assert iterator.deps == []
    assert %State{version: 1, schema: []} = iterator.state
  end

  test "infers dependencies from initial State and body input" do
    iterator = iterator()

    flow =
      Jido.Flow.new!(
        name: "iterator_dependencies",
        nodes: [Jido.Flow.Node.new!(name: "seed", action: Add), iterator],
        return: Ref.result("count")
      )

    assert Enum.find(flow.nodes, &match?(%Iterator{}, &1)).deps == ["seed"]
  end

  test "requires a bounded completion condition" do
    attrs = [
      name: "bad",
      action: Add,
      state: State.new!(schema: [], initial: %{}, update: Ref.body_result()),
      completion: %Condition{operator: :eq, operands: [Ref.value(true), Ref.value(true)]}
    ]

    assert {:error, %InvalidInputError{message: message}} = Iterator.new(attrs)
    assert message =~ "max_iterations"
  end

  test "rejects State refs outside the Iterator scope" do
    assert {:error, %InvalidInputError{details: %{ref_type: :state}}} =
             State.new(
               schema: [],
               initial: %{value: Ref.state(:value)},
               update: Ref.body_result()
             )
  end

  test "rejects body result refs from initial State" do
    assert {:error, %InvalidInputError{details: %{ref_type: :body_result}}} =
             State.new(
               schema: [],
               initial: %{value: Ref.body_result(:value)},
               update: Ref.body_result()
             )
  end

  test "returns a validation error for an improper body input list" do
    assert {:error,
            %InvalidInputError{
              message: "iterator body input must be a proper list",
              details: %{path: [:input]}
            }} = Iterator.new(%{iterator() | input: [Ref.state(:value) | :tail]})
  end

  test "emits a semantic Iterator map without engine values" do
    map = Iterator.to_map(iterator())

    assert map.kind == :iterate
    assert map.name == "count"
    assert map.action == Add
    assert map.state.kind == :iterate_state
    assert map.state.version == 1
    assert map.max_iterations == 5
  end

  defp iterator do
    Iterator.new!(
      name: "count",
      action: Add,
      input: %{value: Ref.state(:value), amount: Ref.value(1)},
      state:
        State.new!(
          schema: [],
          initial: %{value: Ref.result("seed", :value)},
          update: Ref.body_result()
        ),
      completion: %Condition{
        operator: :gte,
        operands: [Ref.state(:value), Ref.value(3)]
      },
      max_iterations: 5
    )
  end
end
