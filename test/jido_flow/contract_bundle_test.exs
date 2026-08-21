defmodule Jido.Flow.ContractBundleTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Action.Error.InvalidInputError
  alias Jido.Flow.ContractBundle
  alias JidoTest.TestActions.Add

  describe "new/1" do
    test "builds the exact host-only contract bundle value" do
      schemas = %{"input/v1" => Zoi.object(%{value: Zoi.integer()}), "output/v1" => []}
      registries = %{"actions/v1" => %{"add/v1" => Add}}

      assert {:ok, bundle} =
               ContractBundle.new(
                 id: "acme.orders/v1",
                 schemas: schemas,
                 action_registries: registries
               )

      assert %ContractBundle{
               id: "acme.orders/v1",
               schemas: ^schemas,
               action_registries: ^registries
             } = bundle

      assert Map.keys(Map.from_struct(bundle)) |> Enum.sort() ==
               [:action_registries, :id, :schemas]
    end

    test "accepts identifier boundaries and the complete stable grammar" do
      for id <- ["a", "A0._/:@-", "a" <> String.duplicate("-", 254)] do
        assert {:ok, %ContractBundle{id: ^id}} =
                 ContractBundle.new(id: id, schemas: %{}, action_registries: %{})
      end
    end

    test "rejects invalid identifiers without creating atoms" do
      unknown = "__jido_bundle_#{System.unique_integer([:positive])}"
      assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end

      for id <- ["", "-bad", "bad id", "mödule", "a" <> String.duplicate("x", 255), unknown] do
        assert {:error,
                %InvalidInputError{
                  message: "invalid flow contract identifier",
                  details: %{field: :id, path: [:id]}
                }} = ContractBundle.new(id: id, schemas: %{}, action_registries: %{})
      end

      assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
    end

    test "requires exact attributes" do
      assert {:error,
              %InvalidInputError{
                message: "contract_bundle is missing required field: :action_registries",
                details: %{record: :contract_bundle, field: :action_registries}
              }} = ContractBundle.new(%{id: "bundle/v1", schemas: %{}})

      assert {:error,
              %InvalidInputError{
                message: "contract_bundle contains unknown field: :extra",
                details: %{record: :contract_bundle, field: :extra}
              }} =
               ContractBundle.new(%{
                 id: "bundle/v1",
                 schemas: %{},
                 action_registries: %{},
                 extra: true
               })
    end

    test "validates schema and registry indexes and rejects source-only atom aliases" do
      assert {:error,
              %InvalidInputError{
                message:
                  "flow contract bundle schemas must map stable identifiers to schema terms",
                details: %{field: :schemas}
              }} = ContractBundle.new(id: "bundle/v1", schemas: [], action_registries: %{})

      assert {:error, %InvalidInputError{message: "invalid flow contract identifier"}} =
               ContractBundle.new(
                 id: "bundle/v1",
                 schemas: %{"-input" => []},
                 action_registries: %{}
               )

      assert {:error,
              %InvalidInputError{
                message:
                  "flow contract bundle action_registries must map stable identifiers to Action registries",
                details: %{field: :action_registries}
              }} = ContractBundle.new(id: "bundle/v1", schemas: %{}, action_registries: [])

      for registry <- [%{add: Add}, %{"add/v1" => "not-a-module"}] do
        assert {:error,
                %InvalidInputError{
                  message:
                    "flow contract bundle action_registries must map stable identifiers to Action registries",
                  details: %{field: :action_registries}
                }} =
                 ContractBundle.new(
                   id: "bundle/v1",
                   schemas: %{},
                   action_registries: %{"actions/v1" => registry}
                 )
      end
    end

    test "accepts an unloaded module atom without loading it" do
      action = unique_module("BundleUnloadedAction")
      refute Code.ensure_loaded?(action)

      assert {:ok, bundle} =
               ContractBundle.new(
                 id: "bundle/v1",
                 schemas: %{},
                 action_registries: %{"actions/v1" => %{"unloaded/v1" => action}}
               )

      assert bundle.action_registries["actions/v1"]["unloaded/v1"] == action
      refute Code.ensure_loaded?(action)
    end
  end

  describe "new!/1" do
    test "returns a bundle or raises the validation error" do
      assert %ContractBundle{id: "bundle/v1"} =
               ContractBundle.new!(id: "bundle/v1", schemas: %{}, action_registries: %{})

      assert_raise InvalidInputError, "invalid flow contract identifier", fn ->
        ContractBundle.new!(id: "-bad", schemas: %{}, action_registries: %{})
      end
    end
  end

  describe "normalize_collection/1" do
    test "requires stable matching keys and ContractBundle structs" do
      bundle = ContractBundle.new!(id: "bundle/v1", schemas: %{}, action_registries: %{})

      assert {:ok, %{"bundle/v1" => ^bundle}} =
               ContractBundle.normalize_collection(%{"bundle/v1" => bundle})

      assert {:error,
              %InvalidInputError{
                message:
                  "flow contract bundles must map stable bundle identifiers to ContractBundle structs",
                details: %{field: :contract_bundles}
              }} = ContractBundle.normalize_collection(%{bundle: bundle})

      assert {:error,
              %InvalidInputError{
                message: "flow contract bundle key does not match bundle identifier",
                details: %{key: "other/v1", bundle: "bundle/v1"}
              }} = ContractBundle.normalize_collection(%{"other/v1" => bundle})
    end
  end
end
