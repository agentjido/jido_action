defmodule Jido.Flow.RegistryTest do
  use ExUnit.Case, async: true

  alias Jido.Flow.Error.InvalidDefinitionError
  alias Jido.Flow.Registry
  alias JidoActionTest.Fixtures.NestedFlow
  alias JidoActionTest.Fixtures.Actions.Add

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
    assert {:ok, ^registry} = Registry.new(registry)

    assert {:error, %InvalidDefinitionError{}} =
             Registry.resolve(registry, "flows/nested", :action)

    assert {:error, %InvalidDefinitionError{}} = Registry.resolve(registry, "missing", :action)
    assert {:error, %InvalidDefinitionError{}} = Registry.resolve(registry, :invalid, :action)
  end

  test "aliases are read-only and must point directly to one write entry" do
    assert {:error, %InvalidDefinitionError{}} =
             Registry.new(%{
               "flows/current" => {:flow, NestedFlow},
               "flows/old" => {:alias, "flows/older"},
               "flows/older" => {:alias, "flows/current"}
             })

    assert {:error, %InvalidDefinitionError{}} =
             Registry.new(%{"flows/old" => {:alias, "flows/missing"}})
  end

  test "Registry does not infer identifiers or module names" do
    registry = Registry.new!(%{"actions/add" => {:action, Add}})

    assert {:error, %InvalidDefinitionError{}} =
             Registry.resolve(registry, "Elixir.String", :action)

    assert {:error, %InvalidDefinitionError{}} =
             Registry.identifier(registry, :flow, NestedFlow)
  end

  test "Registry enforces its size limit and raising constructor" do
    entries = Map.new(1..10_001, &{"actions/#{&1}", {:action, Add}})

    assert {:error, %InvalidDefinitionError{}} = Registry.new(entries)

    assert_raise InvalidDefinitionError, fn -> apply(Registry, :new!, [:invalid]) end
  end

  test "Registry reports bounded invalid entry types" do
    assert {:error, %InvalidDefinitionError{}} = Registry.new([])

    for identifier <- [nil, "bad space", String.duplicate("a", 256)] do
      assert {:error, %InvalidDefinitionError{}} =
               Registry.new(%{identifier => {:action, Add}})
    end

    for entry <- [{:action, nil}, {:flow, nil}, {:atom, "not-atom"}, {:bad, Add}] do
      assert {:error, %InvalidDefinitionError{}} = Registry.new(%{"invalid" => entry})
    end

    for entry <- ["binary", 1, [], %{}, 1.5] do
      assert {:error, %InvalidDefinitionError{details: %{entry: type}}} =
               Registry.new(%{"invalid" => entry})

      assert type in [:binary, :integer, :list, :map, :other]
    end

    assert {:error, %InvalidDefinitionError{}} =
             Registry.new(%{"one" => {:action, Add}, "two" => {:action, Add}})
  end

  test "Registry defends against malformed alias state" do
    alias_to_alias = %Registry{
      entries: %{
        "old" => {:alias, "new"},
        "new" => {:alias, "current"},
        "current" => {:action, Add}
      },
      write_ids: %{}
    }

    missing_write = %Registry{
      entries: %{"old" => {:alias, "missing"}},
      write_ids: %{}
    }

    assert {:error, %InvalidDefinitionError{}} =
             Registry.resolve(alias_to_alias, "old", :action)

    assert {:error, %InvalidDefinitionError{}} =
             Registry.resolve(missing_write, "old", :action)
  end
end
