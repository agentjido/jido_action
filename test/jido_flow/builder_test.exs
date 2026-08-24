defmodule Jido.Flow.BuilderTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Flow
  alias Jido.Flow.Builder
  alias Jido.Flow.Choice
  alias Jido.Flow.Condition
  alias Jido.Flow.Constructor
  alias Jido.Flow.Iterator
  alias Jido.Flow.Map, as: FlowMap
  alias Jido.Flow.Node
  alias Jido.Flow.Reduce
  alias Jido.Flow.Ref
  alias Jido.Flow.State

  alias JidoTest.TestActions.{Add, EchoParamsAction, Multiply}

  test "builds named nodes with named result references" do
    builder =
      Builder.new(name: "builder_math")
      |> Builder.step("added", Add, %{value: Builder.input(:value), amount: 1})
      |> Builder.step("doubled", Multiply, %{
        value: Builder.result("added", :value),
        amount: 2
      })
      |> Builder.return(Builder.result("doubled"))

    assert {:ok, flow} = Builder.build(builder)
    assert [%{name: "added"}, %{name: "doubled"}] = flow.nodes
    assert flow.return == Ref.result("doubled")
    assert {:ok, %{value: 8}} = Jido.Exec.run(flow, %{value: 3}, %{})
  end

  test "prepends node specifications internally and restores declaration order at build time" do
    builder =
      Builder.new(name: "builder_order")
      |> Builder.step("first", EchoParamsAction, %{})
      |> Builder.step("second", EchoParamsAction, %{})
      |> Builder.step("third", EchoParamsAction, %{})
      |> Builder.return(Builder.result("third"))

    assert Enum.map(builder.reversed_node_specs, & &1.name) == ["third", "second", "first"]
    refute Map.has_key?(builder, :node_specs)

    assert {:ok, flow} = Builder.build(builder)
    assert Enum.map(flow.nodes, & &1.name) == ["first", "second", "third"]
  end

  test "uses the canonical Flow constructor and validation path" do
    builder =
      Builder.new(name: "builder_parity", description: "Shared construction")
      |> Builder.step("echo", EchoParamsAction, %{value: Builder.input(:value)},
        after: [],
        meta: %{source: :builder}
      )

    assert {:ok, built} = Builder.build(builder)

    assert {:ok, direct} =
             Flow.new(%{
               name: "builder_parity",
               description: "Shared construction",
               nodes: [
                 %{
                   name: "echo",
                   action: EchoParamsAction,
                   input: %{value: Ref.input(:value)},
                   deps: [],
                   provenance: %{source: :builder}
                 }
               ],
               return: Ref.result("echo")
             })

    assert Flow.to_map(built, provenance: true) == Flow.to_map(direct, provenance: true)
  end

  test "infers output only from one terminal node" do
    terminal =
      Node.new!(
        name: "terminal",
        action: EchoParamsAction,
        input: %{value: Ref.result("source", :value)}
      )

    source = Node.new!(name: "source", action: EchoParamsAction)

    assert {:ok, flow} = Constructor.build(name: "one_terminal", nodes: [terminal, source])
    assert flow.return == Ref.result("terminal")

    assert {:error, error} =
             Constructor.build(
               name: "ambiguous_terminals",
               nodes: [
                 Node.new!(name: "left", action: EchoParamsAction),
                 Node.new!(name: "right", action: EchoParamsAction)
               ]
             )

    assert error.message == "Flow with multiple terminal nodes must declare an output"
    assert error.details.path == [:return]
    assert error.details.terminals == ["left", "right"]
  end

  test "supports canonical collection, choice, and Iterator values" do
    condition = Builder.eq(Builder.input(:route), Builder.value(:add))

    builder =
      Builder.new(name: "closed_builder")
      |> Builder.choice(
        "route",
        [Builder.option("add", condition, Add, %{value: 1, amount: 1})],
        Builder.fallback(Multiply, %{value: 1, amount: 2})
      )
      |> Builder.map(
        "mapped",
        Builder.input(:items),
        Multiply,
        %{value: Builder.item(), amount: Builder.result("route", :value)}
      )
      |> Builder.reduce(
        "total",
        Builder.result("mapped"),
        %{value: 0},
        Add,
        %{value: Builder.accumulator(:value), amount: Builder.item(:value)}
      )
      |> Builder.iterate(
        "counted",
        Add,
        %{value: Builder.state(:value), amount: 1},
        %{
          schema: [],
          initial: %{value: Builder.result("total", :value)},
          update: %{value: Builder.body_result(:value)}
        },
        repeat: 2
      )

    assert {:ok, flow} = Builder.build(builder)
    assert Enum.map(flow.nodes, & &1.name) == ["route", "mapped", "total", "counted"]
    assert flow.return == Ref.result("counted")
  end

  test "requires explicit node names" do
    builder =
      Builder.new(name: "missing_name")
      |> Builder.step(nil, Add, %{value: 1})

    assert {:error, error} = Builder.build(builder)
    assert Exception.message(error) == "node name must be a non-empty string or atom"
    assert error.details == %{path: [:nodes, 0]}
  end

  test "canonical construction returns errors for improper runtime lists" do
    step = %{kind: :step, name: "echo", action: EchoParamsAction, input: %{}}

    assert {:error, %Jido.Action.Error.InvalidInputError{}} =
             Constructor.build(%{
               name: "bad_specs",
               nodes: [step | :tail],
               return: Ref.result("echo")
             })

    assert {:error, %Jido.Action.Error.InvalidInputError{}} =
             Constructor.build(%{
               name: "bad_deps",
               nodes: [Map.put(step, :deps, ["first" | :tail])],
               return: Ref.result("echo")
             })
  end

  test "rejects options that replace positional Step fields" do
    builder =
      Builder.new(name: "protected_step")
      |> Builder.step("original", Add, %{value: 1},
        kind: :map,
        name: "changed",
        action: Multiply,
        input: %{value: 9},
        collection: Builder.value([1])
      )

    assert {:error, error} = Builder.build(builder)
    assert Exception.message(error) == "Builder step received unsupported options"

    assert error.details.options == [:action, :collection, :input, :kind, :name]
    assert error.details.path == [:nodes, 0, :options]
  end

  test "does not expose assignment-era forms" do
    refute function_exported?(Builder, :binding, 1)
    refute function_exported?(Builder, :bind, 2)
    refute function_exported?(Builder, :branch, 2)
    refute function_exported?(Builder, :branch, 3)
    refute function_exported?(Builder, :group, 2)
    refute function_exported?(Builder, :group, 3)
  end

  test "select appends a path to a canonical reference" do
    assert Builder.select(Builder.result("load", :payload), [:items, 0]) ==
             Ref.result("load", [:payload, :items, 0])
  end

  test "exposes the complete runtime reference and condition vocabulary" do
    assert Builder.context(:request) == Ref.context(:request)
    assert Builder.value(:ready) == Ref.value(:ready)
    assert Builder.item(:value) == Ref.item(:value)
    assert Builder.item_index() == Ref.item_index()
    assert Builder.item_id() == Ref.item_id()
    assert Builder.accumulator(:value) == Ref.accumulator(:value)
    assert Builder.state(:value) == Ref.state(:value)
    assert Builder.iteration_index() == Ref.iteration_index()
    assert Builder.body_result(:value) == Ref.body_result(:value)

    left = Builder.value(1)
    right = Builder.value(2)

    for {condition, operator} <- [
          {Builder.eq(left, right), :eq},
          {Builder.neq(left, right), :neq},
          {Builder.lt(left, right), :lt},
          {Builder.lte(left, right), :lte},
          {Builder.gt(left, right), :gt},
          {Builder.gte(left, right), :gte},
          {Builder.in(left, [right]), :in},
          {Builder.all([Builder.eq(left, right)]), :all},
          {Builder.any([Builder.eq(left, right)]), :any},
          {Builder.not(Builder.eq(left, right)), :not}
        ] do
      assert condition.operator == operator
    end
  end

  test "rejects invalid Builder metadata and node option containers" do
    assert_raise ArgumentError, "invalid Flow metadata", fn ->
      Builder.new([{:name, "bad"} | :tail])
    end

    for options <- [[after: [], after: ["duplicate"]], [{:after, []} | :tail], :invalid] do
      builder =
        Builder.new(name: "invalid_options")
        |> Builder.step("echo", EchoParamsAction, %{}, options)

      assert {:error, error} = Builder.build(builder)

      assert Exception.message(error) ==
               "Builder node options must be a keyword list with unique keys"
    end
  end

  test "canonical constructor accepts every prebuilt node kind" do
    nodes = [
      Node.new!(name: "step", action: Add),
      Choice.new!(
        name: "choice",
        options: [
          [
            name: "yes",
            condition: Condition.eq(Ref.value(1), Ref.value(1)),
            action: Add
          ]
        ],
        fallback: [action: Multiply]
      ),
      FlowMap.new!(name: "map", collection: Ref.value([]), action: Add, input: Ref.item()),
      Reduce.new!(
        name: "reduce",
        collection: Ref.value([]),
        initial: Ref.value(%{}),
        action: Add,
        input: %{value: Ref.accumulator(), amount: Ref.item()}
      ),
      Iterator.new!(
        name: "iterate",
        action: Add,
        input: %{value: Ref.state(:value)},
        state: State.new!(schema: [], initial: %{value: 0}, update: Ref.body_result()),
        completion: %Condition{
          operator: :gte,
          operands: [Ref.iteration_index(), Ref.value(1)]
        },
        max_iterations: 1
      )
    ]

    assert {:ok, flow} =
             Constructor.build(name: "prebuilt", nodes: nodes, return: Ref.result("iterate"))

    assert Enum.map(flow.nodes, & &1.name) == ["step", "choice", "map", "reduce", "iterate"]
    assert flow.return == Ref.result("iterate")
  end

  test "canonical constructor revalidates a prebuilt node at its indexed path" do
    invalid = %{Node.new!(name: "invalid", action: Add) | deps: [1]}

    assert {:error, error} =
             Constructor.build(
               name: "invalid_prebuilt",
               nodes: [invalid],
               return: Ref.result("invalid")
             )

    assert error.message == "node deps must be a list of step names"
    assert error.details == %{path: [:nodes, 0]}
  end

  test "canonical constructor validates data node specifications" do
    base = %{kind: :step, name: "step", action: Add}

    invalid = [
      {:invalid, "construction attributes"},
      {%{name: "missing_nodes"}, "nodes must be a list"},
      {%{name: "bad_nodes", nodes: :bad}, "nodes must be a list"},
      {%{name: "bad_node", nodes: [:bad]}, "node specification must be a map"},
      {%{name: "missing_kind", nodes: [%{name: "step", action: Add}]}, "node kind is required"},
      {%{name: "bad_kind", nodes: [%{base | kind: :unknown}]}, "unsupported flow node kind"},
      {%{name: "bad_key", nodes: [Map.put(base, :unknown, true)]},
       "unknown step configuration key"},
      {%{name: "bad_provenance", nodes: [Map.put(base, :provenance, :bad)]},
       "node provenance must be a map"},
      {%{name: "empty", nodes: []}, "must declare at least one node"}
    ]

    for {attrs, message} <- invalid do
      assert {:error, error} = Constructor.build(attrs)
      assert Exception.message(error) =~ message
    end
  end

  test "canonical constructor accepts normalized termination and dependency forms" do
    first = %{kind: :step, name: "first", action: Add}

    second = %{
      kind: :step,
      name: "second",
      action: Add,
      deps: ["first"],
      provenance: %{line: 2}
    }

    assert {:ok, flow} = Constructor.build(name: "deps", nodes: [first, second])
    assert Enum.find(flow.nodes, &(&1.name == "second")).deps == ["first"]

    state = %{schema: [], initial: %{value: 0}, update: Ref.body_result()}

    iterator = %{
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

    assert {:ok, flow} = Constructor.build(name: "termination", nodes: [iterator])
    assert [%Iterator{}] = flow.nodes
  end

  test "Builder keeps termination validation at build time" do
    state = [schema: [], initial: %{value: 0}]

    invalid = [
      {[1], [repeat: 1], "state configuration must be a map"},
      {state, [repeat: 1, max_iterations: 2], "repeat must not set max_iterations"},
      {state, [repeat: 0], "repeat count"},
      {state, [until: Ref.value(true)], "max_iterations"},
      {state, [repeat: 1, until: Ref.value(true)], "exactly one"}
    ]

    for {iterator_state, options, message} <- invalid do
      builder =
        Builder.new(name: "invalid")
        |> Builder.iterate("bad", Add, %{}, iterator_state, options)

      assert {:error, error} = Builder.build(builder)
      assert Exception.message(error) =~ message
    end
  end

  test "Builder preserves every Iterator termination form and canonical precedence" do
    state = %{schema: [], initial: %{value: 0}, update: Ref.body_result()}
    until_condition = Builder.gte(Ref.state(:value), Ref.value(3))
    while_condition = Builder.lt(Ref.state(:value), Ref.value(3))
    canonical_condition = Builder.eq(Ref.state(:value), Ref.value(9))

    cases = [
      {[until: until_condition, max_iterations: 5], until_condition, 5},
      {[
         while: while_condition,
         max_iterations: 5
       ], %Condition{operator: :not, operands: [while_condition]}, 5},
      {[
         repeat: 3
       ],
       %Condition{
         operator: :gte,
         operands: [Ref.iteration_index(), Ref.value(3)]
       }, 3},
      {[
         completion: canonical_condition,
         while: while_condition,
         max_iterations: 5
       ], canonical_condition, 5}
    ]

    for {options, expected_completion, expected_max_iterations} <- cases do
      builder =
        Builder.new(name: "termination_form")
        |> Builder.iterate("iterate", Add, %{value: Ref.state(:value)}, state, options)

      assert {:ok, %Flow{nodes: [%Iterator{} = iterator]}} = Builder.build(builder)
      assert iterator.completion == expected_completion
      assert iterator.max_iterations == expected_max_iterations
    end
  end

  test "canonical constructor rejects authoring aliases" do
    state = %{schema: [], initial: %{value: 0}, update: Ref.body_result()}

    aliases = [
      %{kind: :step, name: "step", action: Add, after: []},
      %{kind: :step, name: "step", action: Add, meta: %{}},
      %{kind: :step, name: "step", action: Add, params: %{}},
      %{kind: :iterate, name: "iterate", action: Add, state: state, repeat: 1}
    ]

    for spec <- aliases do
      assert {:error, error} = Constructor.build(name: "aliases", nodes: [spec])
      assert Exception.message(error) =~ "unknown"
    end
  end
end
