defmodule Jido.Authoring.ValueTest do
  use Covenant.Case, component: "jido_action.authoring", async: true
  @moduletag obligation: "jido_action.authoring.I2"

  alias Jido.Authoring.{Registry, Value}
  alias Jido.Authoring.Value.Error

  test "round trips portable values and registered atoms" do
    registry =
      Registry.new!(%{
        "atoms/count" => {:atom, :count},
        "atoms/ready" => {:atom, :ready}
      })

    value = %{"status" => :ready, 3 => [true, nil], count: 2}

    assert {:ok, encoded} = Value.encode(value, registry)
    assert {:ok, ^value} = Value.decode(encoded, registry)
  end

  test "rejects unregistered atoms and nonportable values" do
    registry = Registry.new!(%{})

    assert {:error, %Registry.Error{}} = Value.encode(:missing, registry)
    assert {:error, %Error{}} = Value.encode(self(), registry)
    assert {:error, %Error{}} = Value.encode({:tuple}, registry)
  end

  test "rejects unsupported map keys before it sorts portable keys" do
    registry = Registry.new!(%{})

    assert {:error, %Error{reason: :map_key, path: []}} =
             Value.encode(%{{:unsupported, :key} => self()}, registry)
  end

  test "rejects a Registry value that is not an atom for an atom tag" do
    registry = Registry.new!(%{"atoms/invalid" => {:atom, "not-an-atom"}})
    encoded = %{"$type" => "atom", "id" => "atoms/invalid"}

    assert {:error, %Error{reason: :atom}} = Value.decode(encoded, registry)
  end

  test "decode rejects invalid UTF-8 strings at every value position" do
    registry = Registry.new!(%{})
    invalid = <<255>>

    for encoded <- [
          invalid,
          [invalid],
          %{"$type" => "map", "entries" => [%{"key" => invalid, "value" => 1}]},
          %{"$type" => "map", "entries" => [%{"key" => "key", "value" => invalid}]}
        ] do
      assert {:error, %Error{reason: :string}} = Value.decode(encoded, registry)
    end
  end

  test "decode rejects a plain map that would become a struct" do
    registry =
      Registry.new!(%{
        "atoms/struct" => {:atom, :__struct__},
        "atoms/uri" => {:atom, URI}
      })

    encoded = %{
      "$type" => "map",
      "entries" => [
        %{
          "key" => %{"$type" => "atom", "id" => "atoms/struct"},
          "value" => %{"$type" => "atom", "id" => "atoms/uri"}
        }
      ]
    }

    assert {:error, %Error{reason: :value}} = Value.decode(encoded, registry)
  end

  test "decode returns structured errors for improper lists" do
    registry = Registry.new!(%{})
    encoded_map = %{"$type" => "map", "entries" => [%{"key" => "key", "value" => 1} | :tail]}

    assert {:error, %Error{reason: :list, path: []}} = Value.decode([1 | :tail], registry)

    assert {:error, %Error{reason: :list, path: ["entries"]}} =
             Value.decode(encoded_map, registry)
  end

  test "every decoded portable value can be encoded again" do
    registry = Registry.new!(%{"atoms/ready" => {:atom, :ready}})

    for encoded <- [
          nil,
          true,
          1,
          2.5,
          "value",
          [1, %{"$type" => "atom", "id" => "atoms/ready"}],
          %{
            "$type" => "map",
            "entries" => [
              %{"key" => "status", "value" => %{"$type" => "atom", "id" => "atoms/ready"}}
            ]
          }
        ] do
      assert {:ok, value} = Value.decode(encoded, registry)
      assert {:ok, _encoded_again} = Value.encode(value, registry)
    end
  end
end
