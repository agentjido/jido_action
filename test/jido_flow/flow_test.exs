defmodule JidoActionTest.FlowTest do
  use ExUnit.Case, async: true

  alias Jido.Action.Error.InvalidInputError
  alias Jido.Flow
  alias Jido.Flow.{Choice, Condition, Node, Ref}
  alias JidoActionTest.TestActions.{Add, EchoParamsAction, MissingRun, Multiply}

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

  test "normalizes Flow structs and rejects invalid public subjects" do
    flow =
      Flow.new!(
        name: "normalized_struct",
        nodes: [Node.new!(name: "echo", action: EchoParamsAction)],
        return: Ref.result("echo")
      )

    assert {:ok, ^flow} = Flow.new(flow)

    assert {:error, %InvalidInputError{message: "flow configuration must be a map"}} =
             Flow.new(:invalid)

    assert {:error, %InvalidInputError{message: "expected a Jido.Flow artifact"}} =
             Flow.validate(:invalid)

    assert Flow.canonical_nodes([]) == []
  end

  test "direct construction and validation revalidate prebuilt nodes" do
    invalid = %{Node.new!(name: "invalid", action: Add) | deps: [1]}

    assert {:error, new_error} =
             Flow.new(
               name: "invalid_new",
               nodes: [invalid],
               return: Ref.result("invalid")
             )

    invalid_flow = %Flow{
      name: "invalid_validate",
      description: nil,
      schema: [],
      output_schema: [],
      nodes: [invalid],
      return: Ref.result("invalid"),
      provenance: %{}
    }

    assert {:error, validate_error} = Flow.validate(invalid_flow)

    for error <- [new_error, validate_error] do
      assert error.message == "node deps must be a list of step names"
      assert error.details == %{}
    end
  end

  test "validates Flow fields before direct node data" do
    assert {:error, new_error} = Flow.new(name: nil, nodes: [:invalid], return: nil)

    invalid_flow = %Flow{
      name: nil,
      description: nil,
      schema: [],
      output_schema: [],
      nodes: [:invalid],
      return: nil,
      provenance: %{}
    }

    assert {:error, validate_error} = Flow.validate(invalid_flow)

    for error <- [new_error, validate_error] do
      assert error.message == "flow name must be a string"
    end
  end

  test "returns focused configuration errors for invalid Flow data" do
    node = Node.new!(name: "echo", action: EchoParamsAction)
    base = %{name: "invalid", nodes: [node], return: Ref.result("echo")}

    invalid = [
      {Map.put(base, :unknown, true), "unknown Flow configuration key"},
      {%{base | name: ""}, "Action name cannot be blank"},
      {Map.put(base, :description, :bad), "description must be a string"},
      {Map.put(base, :schema, :bad), "schema must be a Zoi schema"},
      {Map.put(base, :output_schema, :bad), "output_schema must be a Zoi schema"},
      {%{base | nodes: :bad}, "flow nodes must be a list"},
      {%{base | nodes: [:bad]}, "node configuration must be a map"},
      {%{base | return: nil}, "return ref is required"},
      {%{base | return: Ref.value(1)}, "return must reference"},
      {%{base | return: Ref.result("missing")}, "unknown step"},
      {Map.put(base, :provenance, :bad), "flow provenance must be a map"}
    ]

    for {attrs, message} <- invalid do
      assert {:error, error} = Flow.new(attrs)
      assert Exception.message(error) =~ message
    end
  end

  test "validates compile-time Flow configuration as data" do
    assert {:ok, config} =
             Flow.__validate_config__(%{
               name: "module_flow",
               description: nil,
               schema: nil,
               output_schema: nil
             })

    assert config.schema == []
    assert config.output_schema == []

    for attrs <- [
          :invalid,
          %{name: "flow", unknown: true},
          %{name: nil},
          %{name: "flow", description: :bad},
          %{name: "flow", schema: :bad},
          %{name: "flow", output_schema: :bad}
        ] do
      assert {:error, %InvalidInputError{}} = Flow.__validate_config__(attrs)
    end
  end

  test "inspection APIs reject structurally invalid Flow values" do
    flow = %Flow{
      name: "invalid",
      description: nil,
      schema: [],
      output_schema: [],
      nodes: [],
      return: nil,
      provenance: %{}
    }

    for function <- [:dependencies, :explain, :semantic_identity] do
      assert {:error, %InvalidInputError{message: "return ref is required"}} =
               apply(Flow, function, [flow])
    end
  end
end
