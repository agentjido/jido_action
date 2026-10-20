defmodule Jido.Authoring.RegistryTest do
  use Covenant.Case, component: "jido_action.authoring", async: true
  @moduletag obligation: "jido_action.authoring.I1"

  alias Jido.Authoring.Registry
  alias Jido.Authoring.Registry.Error

  test "stores typed write entries and resolves direct read aliases" do
    registry =
      Registry.new!(%{
        "actions/add" => {:action, __MODULE__},
        "actions/add-old" => {:alias, "actions/add"},
        "atoms/count" => {:atom, :count},
        "custom/value" => {:custom, self()}
      })

    assert {:ok, __MODULE__} = Registry.resolve(registry, "actions/add-old", :action)
    assert {:ok, "actions/add"} = Registry.identifier(registry, :action, __MODULE__)
    assert {:ok, pid} = Registry.resolve(registry, "custom/value", :custom)
    assert pid == self()
    assert {:error, %Error{}} = Registry.resolve(registry, "actions/add", :flow)
  end

  test "unknown identifiers do not create atoms" do
    registry = Registry.new!(%{})
    identifier = "missing/#{System.unique_integer([:positive])}"

    assert_raise ArgumentError, fn -> String.to_existing_atom(identifier) end
    assert {:error, %Error{}} = Registry.resolve(registry, identifier, :action)
    assert_raise ArgumentError, fn -> String.to_existing_atom(identifier) end
  end

  test "rejects invalid identifiers aliases duplicate writes and oversized maps" do
    for entries <- [
          %{nil => {:atom, :ok}},
          %{"bad space" => {:atom, :ok}},
          %{String.duplicate("a", 256) => {:atom, :ok}},
          %{"bad" => :entry},
          %{"old" => {:alias, "missing"}},
          %{"old" => {:alias, "older"}, "older" => {:alias, "current"}},
          %{"one" => {:atom, :same}, "two" => {:atom, :same}}
        ] do
      assert {:error, %Error{}} = Registry.new(entries)
    end

    oversized = Map.new(0..10_000, &{Integer.to_string(&1), {:atom, :ok}})
    assert {:error, %Error{}} = Registry.new(oversized)
  end
end
