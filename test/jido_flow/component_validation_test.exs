defmodule Jido.Flow.ComponentValidationTest do
  use ExUnit.Case, async: true

  alias Jido.Flow.Error.InvalidDefinitionError
  alias Jido.Flow.Choice
  alias Jido.Flow.Condition
  alias Jido.Flow.Data
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
          &Iterate.new/1
        ] do
      assert {:error, %InvalidDefinitionError{}} = constructor.(%{legacy: true})
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

  test "explicit after order is preserved" do
    step = Step.new!(name: "step", action: Add, after: ["second", "first"])
    assert step.after == ["second", "first"]
  end
end
