defmodule Jido.Flow.ComponentValidationTest do
  use ExUnit.Case, async: true

  alias Jido.Flow.Error.InvalidDefinitionError
  alias Jido.Flow.Choice
  alias Jido.Flow.Component
  alias Jido.Flow.Condition
  alias Jido.Flow.Data
  alias Jido.Flow.Dispatch
  alias Jido.Flow.Iterate
  alias Jido.Flow.Map, as: FlowMap
  alias Jido.Flow.Reduce
  alias Jido.Flow.Ref
  alias Jido.Flow.Step
  alias Jido.Flow.Subflow
  alias JidoActionTest.Fixtures.NestedFlow
  alias JidoActionTest.Fixtures.Actions.Add

  test "all canonical authoring records are strict structs" do
    option = Choice.Option.new!(name: "add", condition: Condition.eq(1, 1), action: Add)
    fallback = Choice.Fallback.new!(action: Add)
    state = Iterate.State.new!(schema: [], initial: %{}, update: %{})

    assert %Step{} = Step.new!(name: "step", action: Add)
    assert %Subflow{} = Subflow.new!(name: "subflow", flow: NestedFlow)
    assert %Choice{} = Choice.new!(name: "choice", options: [option], fallback: fallback)
    assert %FlowMap{} = FlowMap.new!(name: "map", collection: [], action: Add)
    assert %Reduce{} = Reduce.new!(name: "reduce", collection: [], initial: %{}, action: Add)
    assert %Dispatch{} = Dispatch.new!(name: "dispatch", decision: Add, expander: Add)

    assert %Iterate{} =
             Iterate.new!(
               name: "iterate",
               action: Add,
               state: state,
               completion: Condition.eq(Ref.iteration_index(), 0),
               max_iterations: 1
             )

    for constructor <- [
          &Step.new/1,
          &Subflow.new/1,
          &Choice.new/1,
          &FlowMap.new/1,
          &Reduce.new/1,
          &Iterate.new/1,
          &Dispatch.new/1
        ] do
      assert {:error, %InvalidDefinitionError{}} = constructor.(%{legacy: true})
    end
  end

  test "Step, Subflow, and Dispatch constructors reject non-map configuration" do
    for {module, message} <- [
          {Step, "step configuration must be a map"},
          {Subflow, "subflow configuration must be a map"},
          {Dispatch, "dispatch configuration must be a map"}
        ] do
      assert {:error, %InvalidDefinitionError{message: ^message}} =
               apply(module, :new, [:invalid])

      assert_raise InvalidDefinitionError, message, fn ->
        apply(module, :new!, [:invalid])
      end
    end
  end

  test "params scopes accept only their native local references" do
    assert {:ok, %FlowMap{}} =
             FlowMap.new(name: "map", collection: [], action: Add, params: %{item: Ref.item()})

    assert {:error, %InvalidDefinitionError{}} =
             Step.new(name: "step", action: Add, params: %{item: Ref.item()})

    assert {:error, %InvalidDefinitionError{}} =
             Reduce.new(
               name: "reduce",
               collection: [],
               initial: %{},
               action: Add,
               params: %{state: Ref.state()}
             )
  end

  test "metadata uses only portable data" do
    assert :ok = Data.validate_object(%{"owner" => "team", 1 => [:ready]})

    assert {:error, %InvalidDefinitionError{}} =
             Step.new(name: "step", action: Add, meta: %{fun: fn -> :bad end})

    assert {:error, %InvalidDefinitionError{}} =
             Step.new(name: "step", action: Add, meta: %{pid: self()})
  end

  test "all canonical components use only needs for control dependencies" do
    option = Choice.Option.new!(name: "add", condition: Condition.eq(1, 1), action: Add)
    fallback = Choice.Fallback.new!(action: Add)
    state = Iterate.State.new!(schema: [], initial: %{}, update: %{})

    cases = [
      {Step, [name: "step", action: Add]},
      {Subflow, [name: "subflow", flow: NestedFlow]},
      {Choice, [name: "choice", options: [option], fallback: fallback]},
      {FlowMap, [name: "map", collection: [], action: Add]},
      {Reduce, [name: "reduce", collection: [], initial: %{}, action: Add]},
      {Iterate,
       [
         name: "iterate",
         action: Add,
         state: state,
         completion: Condition.eq(Ref.iteration_index(), 0),
         max_iterations: 1
       ]},
      {Dispatch, [name: "dispatch", decision: Add, expander: Add]}
    ]

    for {module, attrs} <- cases do
      assert {:ok, default} = apply(module, :new, [attrs])
      assert default.needs == []

      assert {:ok, component} =
               apply(module, :new, [Keyword.put(attrs, :needs, [:second, "first"])])

      assert component.needs == ["second", "first"]

      semantic_map = Component.to_map(component)
      assert semantic_map.needs == ["second", "first"]
      refute Map.has_key?(semantic_map, :after)

      assert {:error, %InvalidDefinitionError{message: message}} =
               apply(module, :new, [Keyword.put(attrs, :after, [])])

      assert message =~ "unknown"
      assert message =~ "after"

      for {value, expected_message} <- [
            {"first", "component needs must be a list"},
            {["first" | :tail], "component needs must be a proper list"},
            {[nil], "component needs must contain component names"},
            {["first", "first"], "component needs contains a duplicate"}
          ] do
        assert {:error, %InvalidDefinitionError{message: ^expected_message}} =
                 apply(module, :new, [Keyword.put(attrs, :needs, value)])
      end
    end
  end

  test "effective dependencies combine and de-duplicate needs and result references" do
    step =
      Step.new!(
        name: "step",
        action: Add,
        params: %{value: Ref.result("source")},
        needs: ["gate", "source"]
      )

    assert Component.needs_of(step) == ["gate", "source"]
    assert Component.reference_dependencies(step) == ["source"]
    assert Component.effective_dependencies(step) == ["gate", "source"]
  end

  test "Choice option and fallback names are not dependency targets" do
    choice =
      Choice.new!(
        name: "route",
        options: [[name: "yes", condition: Condition.eq(true, true), action: Add]],
        fallback: [action: Add]
      )

    dependent = Step.new!(name: "dependent", action: Add, needs: ["route"])

    assert {:ok, _flow} =
             Jido.Flow.new(
               name: "valid_choice_dependency",
               components: [choice, dependent],
               output: Ref.result("dependent")
             )

    for invalid_target <- ["yes", "fallback"] do
      invalid_choice = %{choice | needs: [invalid_target]}

      assert {:error,
              %InvalidDefinitionError{
                message: "Flow reference points to an unknown component",
                details: %{owner: "route", component: ^invalid_target}
              }} =
               Jido.Flow.new(
                 name: "invalid_choice_dependency",
                 components: [invalid_choice],
                 output: Ref.result("route")
               )
    end
  end

  test "needs keep unknown, self, and cycle graph validation" do
    unknown = Step.new!(name: "one", action: Add, needs: ["missing"])

    assert {:error,
            %InvalidDefinitionError{
              message: "Flow reference points to an unknown component",
              details: %{owner: "one", component: "missing"}
            }} =
             Jido.Flow.new(
               name: "unknown_dependency",
               components: [unknown],
               output: Ref.result("one")
             )

    self_dependent = Step.new!(name: "one", action: Add, needs: ["one"])

    assert {:error, %InvalidDefinitionError{message: "flow dependency graph contains a cycle"}} =
             Jido.Flow.new(
               name: "self_dependency",
               components: [self_dependent],
               output: Ref.result("one")
             )

    one = Step.new!(name: "one", action: Add, needs: ["two"])
    two = Step.new!(name: "two", action: Add, needs: ["one"])

    assert {:error,
            %InvalidDefinitionError{
              message: "flow dependency graph contains a cycle",
              details: %{components: components}
            }} =
             Jido.Flow.new(
               name: "dependency_cycle",
               components: [one, two],
               output: Ref.result("one")
             )

    assert Enum.sort(components) == ["one", "two"]
  end

  test "constructors reject invalid paths inside nested params" do
    constructors = [
      {Step, [name: "step", action: Add]},
      {Subflow, [name: "child", flow: NestedFlow]},
      {Choice.Option, [name: "option", condition: Condition.eq(1, 1), action: Add]},
      {Choice.Fallback, [action: Add]},
      {FlowMap, [name: "map", collection: [], action: Add]},
      {Reduce, [name: "reduce", collection: [], initial: %{}, action: Add]},
      {Iterate,
       [
         name: "iterate",
         action: Add,
         state: [schema: [], initial: %{}, update: %{}],
         completion: Condition.eq(true, true),
         max_iterations: 1
       ]},
      {Dispatch, [name: "dispatch", decision: Add, expander: Add]}
    ]

    for {module, attrs} <- constructors do
      for ref <- [Ref.input(:value), Ref.context(:value), Ref.result("load", :value)] do
        assert {:ok, _component} = module.new(Keyword.put(attrs, :params, %{nested: [ref]}))

        for path <- [[nil], [:value, nil, "key"], [:value, nil], [:value | :tail], [%{}]] do
          params = %{nested: [%{value: %{ref | path: path}}]}

          assert {:error,
                  %InvalidDefinitionError{
                    message: "flow expression contains an invalid reference path",
                    details: %{path: [:nested, 0, :value]}
                  }} = module.new(Keyword.put(attrs, :params, params))
        end
      end
    end
  end

  test "constructors reject invalid local paths in their valid scopes" do
    for path <- [[nil], [:value, nil], [:value | :tail], [-1]] do
      for ref <- [Ref.item(path), Ref.accumulator(path)] do
        assert {:error, %InvalidDefinitionError{details: %{segment: _}}} =
                 Reduce.new(
                   name: "reduce",
                   collection: [],
                   initial: %{},
                   action: Add,
                   params: %{nested: [ref]}
                 )
      end

      assert {:error, %InvalidDefinitionError{details: %{segment: _}}} =
               FlowMap.new(
                 name: "map",
                 collection: [],
                 action: Add,
                 params: %{nested: [Ref.item(path)]}
               )

      for ref <- [Ref.state(path), Ref.body_result(path)] do
        assert {:error, %InvalidDefinitionError{details: %{segment: _}}} =
                 Iterate.State.new(schema: [], initial: %{}, update: %{nested: [ref]})
      end
    end
  end

  test "constructors reject invalid paths inside conditions and expression operands" do
    for path <- [[nil], [:value | :tail]] do
      ref = Ref.input(path)

      assert {:error, %InvalidDefinitionError{details: %{segment: _}}} =
               Step.new(
                 name: "step",
                 action: Add,
                 params: %{value: Jido.Expr.new!(:add, [ref, 1])}
               )

      assert {:error, %InvalidDefinitionError{details: %{segment: _}}} =
               Condition.new(:eq, [ref, 1])

      assert {:error, %InvalidDefinitionError{details: %{segment: _}}} =
               Choice.new(
                 name: "choice",
                 options: [
                   [
                     name: "option",
                     condition: %Condition{operator: :eq, operands: [ref, 1]},
                     action: Add
                   ]
                 ],
                 fallback: [action: Add]
               )
    end
  end
end
