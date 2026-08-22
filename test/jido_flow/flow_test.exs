defmodule Jido.FlowTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Action.Error.InvalidInputError
  alias Jido.Flow
  alias Jido.Flow.{Choice, Condition, Node, Ref}
  alias JidoTest.TestActions.{Add, EchoParamsAction, MissingRun, Multiply}

  test "builds and orders a canonical Flow" do
    second =
      Node.new!(
        name: "second",
        action: Multiply,
        input: %{value: Ref.result("first", :value), amount: Ref.value(2)}
      )

    first =
      Node.new!(
        name: "first",
        action: Add,
        input: %{value: Ref.input(:value), amount: Ref.value(1)}
      )

    assert {:ok, flow} =
             Flow.new(
               name: "math",
               description: "Canonical math",
               nodes: [second, first],
               return: Ref.result("second")
             )

    assert Enum.map(Flow.canonical_nodes(flow.nodes), & &1.name) == ["first", "second"]
    assert {:ok, %{"first" => [], "second" => ["first"]}} = Flow.dependencies(flow)

    assert %{type: :flow, version: 1, name: "math", nodes: nodes} = Flow.to_map(flow)
    assert Enum.map(nodes, & &1.name) == ["first", "second"]
  end

  test "normalizes names and infers result dependencies" do
    first = Node.new!(name: :first, action: Add)
    second = Node.new!(name: :second, action: Add, input: %{value: Ref.result(:first)})

    flow = Flow.new!(name: "normalized", nodes: [second, first], return: Ref.result(:second))

    assert flow.name == "normalized"
    assert Enum.map(flow.nodes, & &1.name) == ["second", "first"]
    assert Enum.find(flow.nodes, &(&1.name == "second")).deps == ["first"]
  end

  test "returns validation errors for improper constructor lists" do
    node = Node.new!(name: "node", action: Add)

    for attrs <- [
          [{:name, "bad_attrs"} | :tail],
          %{name: "bad_nodes", nodes: [node | :tail], return: Ref.result("node")},
          %{name: "bad_return", nodes: [node], return: [Ref.result("node") | :tail]}
        ] do
      assert {:error, %InvalidInputError{}} = Flow.new(attrs)
    end
  end

  test "rejects duplicate names, unknown dependencies, and cycles" do
    duplicate = Node.new!(name: "same", action: Add)

    assert {:error, %InvalidInputError{message: "duplicate step name: \"same\""}} =
             Flow.new(
               name: "duplicate",
               nodes: [duplicate, duplicate],
               return: Ref.result("same")
             )

    assert {:error, %InvalidInputError{message: message}} =
             Flow.new(
               name: "unknown",
               nodes: [Node.new!(name: "node", action: Add, input: Ref.result("missing"))],
               return: Ref.result("node")
             )

    assert message == "node input points to an unknown step: \"missing\""

    left = Node.new!(name: "left", action: Add, input: Ref.result("right"))
    right = Node.new!(name: "right", action: Add, input: Ref.result("left"))

    assert {:error, %InvalidInputError{message: "flow dependency graph contains a cycle"}} =
             Flow.new(name: "cycle", nodes: [left, right], return: Ref.result("left"))
  end

  test "rejects local references outside collection and Iterator scopes" do
    assert {:error,
            %InvalidInputError{
              message: "flow expression contains a scoped ref outside its valid scope",
              details: %{ref_type: :item}
            }} = Node.new(name: "bad", action: Add, input: %{value: Ref.item()})

    assert {:error,
            %InvalidInputError{
              message: "flow expression contains a scoped ref outside its valid scope",
              details: %{ref_type: :state}
            }} =
             Flow.new(
               name: "bad_return",
               nodes: [Node.new!(name: "ok", action: Add)],
               return: Ref.state()
             )
  end

  test "validates Choice targets and executable Action contracts" do
    choice =
      Choice.new!(
        name: "route",
        options: [
          [
            name: "positive",
            condition: Condition.gt(Ref.input(:value), Ref.value(0)),
            action: Add
          ]
        ],
        fallback: [action: Multiply]
      )

    flow = Flow.new!(name: "choice", nodes: [choice], return: Ref.result("route"))
    assert {:ok, ^flow} = Flow.validate_executable(flow)

    invalid = %{
      flow
      | nodes: [%{List.first(flow.nodes) | fallback: %{choice.fallback | action: MissingRun}}]
    }

    assert {:error, error} = Flow.validate_executable(invalid)
    assert Exception.message(error) == "module is not a valid Jido action"
  end

  test "keeps semantic identity independent of author order and provenance" do
    first = Node.new!(name: "first", action: EchoParamsAction, provenance: %{line: 1})
    second = Node.new!(name: "second", action: EchoParamsAction, deps: ["first"])

    left =
      Flow.new!(
        name: "identity",
        nodes: [first, second],
        return: Ref.result("second"),
        provenance: %{file: "left.ex"}
      )

    right =
      Flow.new!(
        name: "identity",
        nodes: [%{second | provenance: %{line: 9}}, %{first | provenance: %{line: 8}}],
        return: Ref.result("second"),
        provenance: %{file: "right.ex"}
      )

    assert Flow.to_map(left) == Flow.to_map(right)
    assert {:ok, left_identity} = Flow.semantic_identity(left)
    assert {:ok, right_identity} = Flow.semantic_identity(right)
    assert left_identity == right_identity
  end

  test "returns inspection data without exposing an engine value" do
    flow =
      Flow.new!(
        name: "inspect",
        nodes: [Node.new!(name: "echo", action: EchoParamsAction)],
        return: Ref.result("echo")
      )

    assert {:ok, explanation} = Flow.explain(flow)
    assert explanation.kind == :flow
    assert explanation.name == "inspect"
    assert explanation.dependencies == %{"echo" => []}
    assert explanation.edges == []
    assert %{digest: digest, uuid: uuid} = explanation.identity
    assert is_binary(digest)
    assert is_binary(uuid)
  end

  test "raises from new!/1 and rejects non-Flow inspection subjects" do
    assert_raise InvalidInputError, fn -> Flow.new!(name: nil, nodes: [], return: nil) end

    for function <- [:dependencies, :explain, :semantic_identity] do
      assert {:error, %InvalidInputError{message: "expected a Jido.Flow artifact"}} =
               apply(Flow, function, [:not_a_flow])
    end
  end
end
