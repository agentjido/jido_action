defmodule Jido.Flow.RefTest do
  use ExUnit.Case, async: true

  alias Jido.Flow.Error.InvalidDefinitionError
  alias Jido.Flow.Ref

  test "the reference grammar has one source, optional component, and path" do
    assert Ref.input(:id) == %Ref{source: :input, component: nil, path: [:id]}

    assert Ref.result(:load, [:item, 0]) == %Ref{
             source: :result,
             component: "load",
             path: [:item, 0]
           }

    refute Map.has_key?(Map.from_struct(Ref.input(:id)), :value)
  end

  test "result is the only source that accepts a component" do
    assert :ok = Ref.validate(Ref.result("load"))

    assert {:error, %InvalidDefinitionError{}} =
             Ref.validate(%Ref{source: :input, component: "load", path: []})

    assert {:error, %InvalidDefinitionError{}} =
             Ref.validate(%Ref{source: :result, component: nil, path: []})
  end

  test "local sources are checked against the owner scope" do
    assert :ok = Ref.validate(Ref.item(), :map_params)
    assert :ok = Ref.validate(Ref.accumulator(), :reduce_params)
    assert :ok = Ref.validate(Ref.state(), :iterate_completion)
    assert {:error, %InvalidDefinitionError{}} = Ref.validate(Ref.state(), :flow)
    assert {:error, %InvalidDefinitionError{}} = Ref.validate(Ref.item(), :iterate_params)
  end

  test "paths contain only portable path segments" do
    assert :ok = Ref.validate(Ref.input([:payload, "items", 0]))
    assert {:error, %InvalidDefinitionError{}} = Ref.validate(Ref.input([-1]))
    assert {:error, %InvalidDefinitionError{}} = Ref.validate(Ref.input([%{}]))
  end
end
