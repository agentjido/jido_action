defmodule Jido.Flow.NodeTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Action.Error.InvalidInputError
  alias Jido.Flow.Node
  alias Jido.Flow.Ref
  alias JidoTest.TestActions.Add

  describe "new/1" do
    test "accepts keyword attrs and derives dependencies from input refs and explicit deps" do
      assert {:ok, node} =
               Node.new(
                 name: :double,
                 action: Add,
                 input: %{
                   value: Ref.result(:add_one, :value),
                   adjustments: [Ref.result(:load_adjustment, :amount), 1]
                 },
                 deps: [:explicit_dep, :add_one]
               )

      assert node.deps == [:add_one, :explicit_dep]
      assert Node.result_deps(node) == [:add_one, :explicit_dep, :load_adjustment]

      assert Node.to_map(node).input == %{
               value: %{type: :result, node: :add_one, path: [:value]},
               adjustments: [
                 %{type: :result, node: :load_adjustment, path: [:amount]},
                 %{type: :value, value: 1}
               ]
             }
    end

    test "accepts nil input, deps, and provenance as empty values" do
      assert {:ok, node} =
               Node.new(name: :add_one, action: Add, input: nil, deps: nil, provenance: nil)

      assert node.input == %{}
      assert node.deps == []
      assert node.provenance == %{}
    end

    test "rejects malformed node configuration" do
      cases = [
        {"node configuration must be a map", :not_a_map},
        {"node name must be a non-nil atom", %{action: Add}},
        {"node action must be a module atom", %{name: :bad, action: "not a module"}},
        {"node input must be a map", %{name: :bad, action: Add, input: [:value]}},
        {"node deps must be a list", %{name: :bad, action: Add, deps: :not_a_list}},
        {"node deps must be a list of atoms", %{name: :bad, action: Add, deps: [:ok, nil]}},
        {"node provenance must be a map", %{name: :bad, action: Add, provenance: :not_a_map}}
      ]

      for {expected_message, attrs} <- cases do
        assert {:error, %InvalidInputError{message: message}} = Node.new(attrs)
        assert message =~ expected_message
      end
    end

    test "rejects malformed refs and unsupported structs at nested input paths" do
      assert {:error, %InvalidInputError{message: message, details: details}} =
               Node.new(
                 name: :bad,
                 action: Add,
                 input: %{items: [%Ref{type: :result, node: nil, path: [], value: nil}]}
               )

      assert message =~ "node input contains invalid ref"
      assert details.path == [:items, 0]
      assert details.type == :result

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Node.new(name: :bad, action: Add, input: %{value: Date.utc_today()})

      assert message =~ "node input contains unsupported expression"
      assert details.path == [:value]
      assert details.expression == Date
    end

    test "raises validation errors from new!/1" do
      assert_raise InvalidInputError, ~r/node action must be a module atom/, fn ->
        Node.new!(name: :bad, action: nil)
      end
    end
  end
end
