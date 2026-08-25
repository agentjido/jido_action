defmodule Jido.Flow.RegistryTest do
  use ExUnit.Case, async: true

  alias Jido.Action.Error.InvalidInputError
  alias Jido.Flow.Registry
  alias JidoActionTest.FlowFixtures.NestedFlow
  alias JidoActionTest.TestActions.Add

  test "Registry keeps Action and Flow identifiers distinct" do
    registry =
      Registry.new!(%{
        "actions/add" => {:action, Add},
        "flows/nested" => {:flow, NestedFlow},
        "flows/nested-old" => {:alias, "flows/nested"},
        "schemas/empty" => {:schema, []},
        "atoms/ready" => {:atom, :ready}
      })

    assert {:ok, Add} = Registry.resolve(registry, "actions/add", :action)
    assert {:ok, NestedFlow} = Registry.resolve(registry, "flows/nested-old", :flow)
    assert {:ok, "flows/nested"} = Registry.identifier(registry, :flow, NestedFlow)
    assert {:error, %InvalidInputError{}} = Registry.resolve(registry, "flows/nested", :action)
  end

  test "aliases are read-only and must point directly to one write entry" do
    assert {:error, %InvalidInputError{}} =
             Registry.new(%{
               "flows/current" => {:flow, NestedFlow},
               "flows/old" => {:alias, "flows/older"},
               "flows/older" => {:alias, "flows/current"}
             })
  end

  test "Registry does not infer identifiers or module names" do
    registry = Registry.new!(%{"actions/add" => {:action, Add}})
    assert {:error, %InvalidInputError{}} = Registry.resolve(registry, "Elixir.String", :action)
    assert {:error, %InvalidInputError{}} = Registry.identifier(registry, :flow, NestedFlow)
  end
end
