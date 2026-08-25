defmodule JidoActionTest.Flow.IteratorTest do
  use ExUnit.Case, async: true

  alias Jido.Action.Error.InvalidInputError
  alias Jido.Flow.{Condition, Iterator, Ref, State}
  alias JidoActionTest.TestActions.{Add, MissingRun}

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
    iterator = Iterator.new!(%{iterator() | name: :count})
    map = Iterator.to_map(iterator)

    assert iterator.name == "count"
    assert map.kind == :iterate
    assert map.name == "count"
    assert map.action == Add
    assert map.state.kind == :iterate_state
    assert map.state.version == 1
    assert map.max_iterations == 5
  end

  test "normalizes public helpers and includes optional provenance" do
    iterator = iterator()

    assert {:ok, ^iterator} = Iterator.new(iterator)
    assert Iterator.result_deps(iterator) == ["seed"]
    assert Iterator.put_deps(iterator, ["manual"]).deps == ["manual"]
    assert Iterator.check(iterator) == :ok
    assert Iterator.to_map(iterator, provenance: true).provenance == %{}
    assert Iterator.semantic_data(iterator).kind == :iterate

    invalid = %{iterator | action: MissingRun}
    assert {:error, error} = Iterator.check(invalid)
    assert error.details.iterator == "count"
    assert error.details.target == MissingRun
  end

  test "rejects invalid top-level Iterator configuration" do
    assert {:error, error} = Iterator.new(:invalid)
    assert Exception.message(error) == "iterator configuration must be a map"

    assert {:error, error} = Iterator.new([{:name, "count"} | :tail])
    assert Exception.message(error) == "iterator configuration must be a map"

    assert_raise InvalidInputError, fn -> Iterator.new!(name: nil) end

    for {changes, message} <- [
          {%{name: ""}, "iterator name"},
          {%{name: nil}, "iterator name"},
          {%{action: nil}, "body target"},
          {%{state: nil}, "state is required"},
          {%{state: :bad}, "state configuration"},
          {%{completion: nil}, "completion is required"},
          {%{completion: :bad}, "iterator completion condition"},
          {%{max_iterations: 0}, "max_iterations"},
          {%{deps: :bad}, "deps must be a list"},
          {%{deps: ["good", ""]}, "list of step names"},
          {%{deps: ["good", nil]}, "list of step names"},
          {%{provenance: :bad}, "provenance must be a map"},
          {%{unknown: true}, "unknown iterator configuration key"}
        ] do
      attrs = Map.merge(iterator() |> Map.from_struct(), changes)
      assert {:error, error} = Iterator.new(attrs)
      assert Exception.message(error) =~ message
    end
  end

  test "rejects invalid Iterator input references and normalizes dependencies" do
    base = iterator() |> Map.from_struct()

    invalid_inputs = [
      {Ref.item(), "scoped ref outside"},
      {%Ref{type: :state, path: [:ok, 1.5]}, "invalid ref path"},
      {%Ref{type: :unknown, path: []}, "invalid ref"},
      {Date.utc_today(), "unsupported expression"}
    ]

    for {input, message} <- invalid_inputs do
      assert {:error, error} = Iterator.new(%{base | input: input})
      assert Exception.message(error) =~ message
    end

    assert {:ok, normalized} =
             Iterator.new(%{base | deps: [:seed, "seed", "other"], provenance: nil, input: nil})

    assert normalized.deps == ["other", "seed"]
    assert normalized.provenance == %{}
    assert normalized.input == %{}
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
