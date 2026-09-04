defmodule Jido.Action.ZoiUnionTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Action.{Error, Schema, Tool}
  alias Jido.Exec

  defmodule UnionAction do
    use Jido.Action,
      name: "union_action",
      schema:
        Zoi.union([
          Zoi.object(%{name: Zoi.string() |> Zoi.trim(), resource_id: Zoi.string()}),
          Zoi.object(%{name: Zoi.string() |> Zoi.trim(), path: Zoi.string()})
        ])

    def run(params, _context), do: {:ok, params}
  end

  defmodule UnionOutputAction do
    use Jido.Action,
      name: "union_output_action",
      output_schema:
        Zoi.union([
          Zoi.object(%{name: Zoi.string() |> Zoi.trim(), resource_id: Zoi.string()}),
          Zoi.object(%{name: Zoi.string() |> Zoi.trim(), path: Zoi.string()})
        ])

    def run(params, _context), do: {:ok, params}
  end

  defmodule OptionalUnionAction do
    use Jido.Action,
      name: "optional_union_action",
      schema:
        Zoi.union([
          Zoi.object(%{name: Zoi.string() |> Zoi.optional()}),
          Zoi.object(%{count: Zoi.integer()})
        ])

    def run(params, _context), do: {:ok, params}
  end

  defmodule StringUnionAction do
    use Jido.Action,
      name: "string_union_action",
      schema:
        Zoi.union([
          Zoi.object(%{"name" => Zoi.string(), "resource_id" => Zoi.string()}),
          Zoi.object(%{"name" => Zoi.string(), "path" => Zoi.string()})
        ])

    def run(params, _context), do: {:ok, params}
  end

  defmodule ObjectAction do
    use Jido.Action,
      name: "object_key_action",
      schema: Zoi.object(%{name: Zoi.string()})

    def run(params, _context), do: {:ok, params}
  end

  defmodule MixedKeyAction do
    use Jido.Action,
      name: "mixed_key_action",
      schema: Zoi.object(%{"name" => Zoi.integer(), :name => Zoi.string()})

    def run(params, _context), do: {:ok, params}
  end

  defmodule NestedAction do
    use Jido.Action,
      name: "nested_union_action",
      schema:
        Zoi.object(%{
          request:
            Zoi.union([
              Zoi.object(%{name: Zoi.string(), resource_id: Zoi.string()}),
              Zoi.object(%{name: Zoi.string(), path: Zoi.string()})
            ])
        })

    def run(params, _context), do: {:ok, params}
  end

  defmodule MapPayloadAction do
    use Jido.Action,
      name: "map_payload_union_action",
      schema:
        Zoi.union([
          Zoi.object(%{
            kind: Zoi.literal("object"),
            payload: Zoi.object(%{name: Zoi.string()})
          }),
          Zoi.object(%{
            kind: Zoi.literal("map"),
            payload: Zoi.map(Zoi.string(), Zoi.string())
          })
        ])

    def run(params, _context), do: {:ok, params}
  end

  defmodule MixedBranchAction do
    use Jido.Action,
      name: "mixed_branch_union_action",
      schema:
        Zoi.union([
          Zoi.object(%{kind: Zoi.literal("atom"), name: Zoi.string()}),
          Zoi.object(%{"name" => Zoi.string(), :kind => Zoi.literal("string")})
        ])

    def run(params, _context), do: {:ok, params}
  end

  describe "union key extraction" do
    test "collects unique keys from all branches" do
      assert Enum.sort(Schema.known_keys(UnionAction.schema())) == [:name, :path, :resource_id]
    end

    test "collects keys recursively from nested unions" do
      schema = Zoi.union([UnionAction.schema(), Zoi.object(%{count: Zoi.integer()})])
      assert Enum.sort(Schema.known_keys(schema)) == [:count, :name, :path, :resource_id]
    end

    test "does not collect nested object fields as root keys" do
      schema =
        Zoi.union([
          Zoi.object(%{nested: Zoi.object(%{inner: Zoi.string()})}),
          Zoi.object(%{name: Zoi.string()})
        ])

      assert Enum.sort(Schema.known_keys(schema)) == [:name, :nested]
    end

    test "keeps schema-declared string keys" do
      assert Enum.sort(Schema.known_keys(StringUnionAction.schema())) ==
               ["name", "path", "resource_id"]
    end
  end

  describe "union validation through Exec" do
    for selector <- [:resource_id, :path], key_form <- [:atom, :string] do
      test "validates #{selector} with #{key_form} keys and preserves unknown values" do
        params = %{unquote(selector) => "resource", :name => " example "}
        params = input_keys(params, unquote(key_form))
        params = Map.merge(params, %{"extra_string" => 7, extra_atom: 8})

        expected = %{
          "extra_string" => 7,
          :extra_atom => 8,
          :name => "example",
          unquote(selector) => "resource"
        }

        assert {:ok, ^expected} = Exec.run(UnionAction, params)
      end
    end

    test "rejects missing selectors and invalid field types" do
      for params <- [
            %{name: "example"},
            %{"name" => "example"},
            %{name: 123, resource_id: "resource"},
            %{"name" => 123, "path" => "readme.md"}
          ] do
        assert {:error, %Error.InvalidInputError{}} = Exec.run(UnionAction, params)
      end
    end

    test "does not bypass invalid values when a branch accepts an empty map" do
      assert {:error, _} = Zoi.parse(OptionalUnionAction.schema(), %{name: 123})

      for params <- [%{name: 123}, %{"name" => 123}] do
        assert {:error, %Error.InvalidInputError{}} = Exec.run(OptionalUnionAction, params)
      end

      assert {:ok, %{}} = Exec.run(OptionalUnionAction, %{})
      assert {:ok, %{name: "example"}} = Exec.run(OptionalUnionAction, %{name: "example"})
    end

    test "prefers atom keys and removes duplicate string keys" do
      params = %{"name" => 123, :name => "example", :path => "readme.md"}
      assert {:ok, %{name: "example", path: "readme.md"}} = Exec.run(UnionAction, params)
    end

    test "does not replace an invalid atom value with a valid string value" do
      params = %{"name" => "example", :name => nil, :path => "readme.md"}
      assert {:error, %Error.InvalidInputError{}} = Exec.run(UnionAction, params)
    end

    test "does not create atoms from unknown JSON keys" do
      unknown = "unknown_union_key_#{System.unique_integer([:positive])}"
      assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
      params = %{"name" => "example", "path" => "readme.md", unknown => 42}
      assert {:ok, result} = Exec.run(UnionAction, params)
      assert result[unknown] == 42
      assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
    end

    test "preserves schema-declared string keys" do
      params = %{"name" => "example", "path" => "readme.md", "extra" => true}
      assert {:ok, ^params} = Exec.run(StringUnionAction, params)
    end

    test "normalizes known root keys for ordinary Zoi objects as well" do
      assert {:ok, %{name: "example"}} = Exec.run(ObjectAction, %{"name" => "example"})
    end

    test "does not consume separately declared string fields" do
      params = %{"name" => 123, :name => "example"}
      assert {:ok, ^params} = Exec.run(MixedKeyAction, params)
      assert {:error, %Error.InvalidInputError{}} = Exec.run(MixedKeyAction, %{name: "example"})
    end

    test "keeps conflicting key declarations across branches distinct" do
      atom_params = %{kind: "atom", name: "example"}
      assert {:ok, ^atom_params} = Exec.run(MixedBranchAction, atom_params)

      assert {:ok, %{"name" => "example", :kind => "string"}} =
               Exec.run(MixedBranchAction, %{"kind" => "string", "name" => "example"})

      assert {:error, %Error.InvalidInputError{}} =
               Exec.run(MixedBranchAction, %{"kind" => "atom", "name" => "example"})
    end

    test "keeps unions nested in object fields working" do
      params = %{request: %{name: "example", path: "readme.md"}, extra: true}
      assert {:ok, ^params} = Exec.run(NestedAction, params)
    end
  end

  describe "union output validation" do
    test "validates both branches and key forms" do
      for selector <- [:resource_id, :path], key_form <- [:atom, :string] do
        output = %{selector => "resource", :name => " example ", :extra => 42}
        expected = %{selector => "resource", :name => "example", :extra => 42}
        params = input_keys(Map.delete(output, :extra), key_form) |> Map.put(:extra, 42)

        assert {:ok, ^expected} =
                 Exec.run(UnionOutputAction, params, %{}, max_retries: 0)
      end
    end

    test "rejects invalid output" do
      assert {:error, %Error.InvalidInputError{}} =
               Exec.run(UnionOutputAction, %{name: "example"}, %{}, max_retries: 0)
    end
  end

  describe "union tool conversion" do
    test "executes JSON arguments for every root union branch" do
      for selector <- ["resource_id", "path"] do
        params = %{"name" => "example", selector => "resource", "extra" => 42}
        assert {:ok, json} = Tool.execute_action(UnionAction, params, %{})
        assert Jason.decode!(json) == params
      end
    end

    test "does not convert nested keys using a rejected root union branch" do
      params = %{"kind" => "map", "payload" => %{"name" => "keep string"}}

      assert {:ok, %{kind: "map", payload: %{"name" => "keep string"}}} =
               Exec.run(MapPayloadAction, params)

      assert {:ok, json} = Tool.execute_action(MapPayloadAction, params, %{})
      assert Jason.decode!(json) == params

      object_params = %{"kind" => "object", "payload" => %{name: "example"}}
      assert {:ok, json} = Tool.execute_action(MapPayloadAction, object_params, %{})
      assert Jason.decode!(json) == %{"kind" => "object", "payload" => %{"name" => "example"}}
    end

    test "keeps nested union conversion working" do
      params = %{"request" => %{"name" => "example", "path" => "readme.md"}}
      assert {:ok, json} = Tool.execute_action(NestedAction, params, %{})
      assert Jason.decode!(json) == params
    end
  end

  defp input_keys(params, :atom), do: params

  defp input_keys(params, :string),
    do: Map.new(params, fn {key, value} -> {to_string(key), value} end)
end
