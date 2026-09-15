defmodule Jido.Flow.ExpressionPreparationContractTest do
  use ExUnit.Case, async: true

  alias Jido.Flow
  alias Jido.Flow.Choice
  alias Jido.Flow.Dispatch
  alias Jido.Flow.Error.InvalidDefinitionError
  alias Jido.Flow.Iterate
  alias Jido.Flow.Map, as: FlowMap
  alias Jido.Flow.Reduce
  alias Jido.Flow.Ref
  alias Jido.Flow.Step
  alias Jido.Flow.Subflow
  alias JidoActionTest.Fixtures.Actions.Add
  alias JidoActionTest.Fixtures.NestedFlow

  test "every parameter constructor normalizes nested result names and retains its nil rule" do
    params = %{nested: [%Ref{source: :result, component: :source, path: []}]}
    expected = %{nested: [Ref.result("source")]}

    for {module, attrs} <- constructors() do
      assert {:ok, component} = module.new(Keyword.put(attrs, :params, params))
      assert component.params == expected

      assert {:ok, component} = module.new(Keyword.put(attrs, :params, nil))
      assert component.params == if(module in [FlowMap, Reduce], do: %{}, else: nil)
    end
  end

  test "normalization failures precede scope validation across the complete parameter value" do
    params = [Ref.body_result(), %Ref{source: :result, component: "", path: []}]
    {:error, message} = Jido.Action.validate_name("")

    for {module, attrs} <- constructors() do
      assert {:error, %InvalidDefinitionError{} = error} =
               module.new(Keyword.put(attrs, :params, params))

      assert error.message == message
      assert error.details == %{path: [1]}
    end
  end

  test "parameter scopes report the exact nested path" do
    for {module, attrs} <- constructors() do
      scope =
        case module do
          FlowMap -> :map_params
          Reduce -> :reduce_params
          Iterate -> :iterate_params
          _ -> :flow
        end

      ref = if module == Iterate, do: Ref.item(), else: Ref.body_result()

      assert {:error, error} =
               module.new(Keyword.put(attrs, :params, %{nested: [ref]}))

      assert error.message == "flow expression contains a scoped ref outside its valid scope"
      assert error.details == %{path: [:nested, 0], ref_type: ref.source, scope: scope}
    end
  end

  test "required expression fields distinguish nil from absence" do
    assert {:ok, %FlowMap{collection: nil}} =
             FlowMap.new(name: "map", collection: nil, action: Add)

    assert {:ok, %Reduce{collection: nil, initial: nil}} =
             Reduce.new(name: "reduce", collection: nil, initial: nil, action: Add)

    assert {:ok, %Iterate.State{initial: nil, update: nil}} =
             Iterate.State.new(initial: nil, update: nil)

    for {module, attrs, message, field} <- [
          {FlowMap, [name: "map", action: Add], "map collection is required", :collection},
          {Reduce, [name: "reduce", collection: [], action: Add], "reduce initial is required",
           :initial},
          {Iterate.State, [initial: nil], "iterate state update is required", :update}
        ] do
      assert {:error, error} = module.new(attrs)
      assert error.message == message
      assert error.details == %{path: [field]}
    end
  end

  test "nested Choice errors retain component, option, and expression path segments" do
    choice = %Choice{
      name: "route",
      options: [
        %{name: "yes", condition: true, action: Add, params: %{nested: [self()]}}
      ],
      fallback: Choice.Fallback.new!(action: Add)
    }

    assert {:error, local} = Choice.new(choice)
    assert local.details.path == [:options, 0, :nested, 0]

    assert {:error, nested} = Flow.new(name: "nested", components: [choice], output: %{})
    assert nested.message == local.message
    assert nested.details == %{local.details | path: [:components, 0, :options, 0, :nested, 0]}
  end

  defp constructors do
    [
      {Step, [name: "step", action: Add]},
      {Subflow, [name: "child", flow: NestedFlow]},
      {Choice.Option, [name: "yes", condition: true, action: Add]},
      {Choice.Fallback, [action: Add]},
      {FlowMap, [name: "map", collection: [], action: Add]},
      {Reduce, [name: "reduce", collection: [], initial: %{}, action: Add]},
      {Iterate,
       [
         name: "iterate",
         action: Add,
         state: [initial: %{}, update: %{}],
         completion: true,
         max_iterations: 1
       ]},
      {Dispatch, [name: "dispatch", decision: Add, expander: Add]}
    ]
  end
end
