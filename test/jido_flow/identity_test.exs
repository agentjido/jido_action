defmodule Jido.Flow.IdentityTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Action.Error.InvalidInputError
  alias Jido.Flow
  alias Jido.Flow.{Node, Ref}
  alias JidoTest.TestActions.{Add, EchoParamsAction}

  test "returns canonical direct predecessor dependencies" do
    flow = diamond_flow()

    assert {:ok,
            %{
              "a" => [],
              "b" => ["a"],
              "c" => ["a"],
              "d" => ["b", "c"]
            }} = Flow.dependencies(flow)
  end

  test "includes result references and explicit ordering edges as predecessors" do
    flow =
      Flow.new!(
        name: "dependency_sources",
        nodes: [
          Node.new!(name: :root, action: EchoParamsAction),
          Node.new!(
            name: :child,
            action: EchoParamsAction,
            input: %{value: Ref.result(:root, :value)}
          ),
          Node.new!(name: :ordered, action: EchoParamsAction, deps: [:root])
        ],
        return: %{child: Ref.result(:child), ordered: Ref.result(:ordered)}
      )

    assert {:ok, dependencies} = Flow.dependencies(flow)
    assert dependencies["child"] == ["root"]
    assert dependencies["ordered"] == ["root"]
  end

  test "returns the exact explanation contract in canonical order" do
    schema = Zoi.object(%{value: Zoi.integer()})
    output_schema = Zoi.object(%{result: Zoi.integer()})

    flow =
      Flow.new!(
        name: "explainable",
        description: "Exact inspection data",
        schema: schema,
        output_schema: output_schema,
        nodes: [
          Node.new!(
            name: :zeta,
            action: EchoParamsAction,
            provenance: %{line: 20}
          ),
          Node.new!(
            name: :alpha,
            action: EchoParamsAction,
            provenance: %{line: 10}
          )
        ],
        return: %{result: Ref.result(:zeta, :value)},
        provenance: %{source: :test}
      )

    assert {:ok, explanation} = Flow.explain(flow)
    assert {:ok, identity} = Flow.semantic_identity(flow)

    assert Map.keys(explanation) |> Enum.sort() ==
             [
               :dependencies,
               :description,
               :edges,
               :identity,
               :kind,
               :name,
               :nodes,
               :output_schema,
               :return,
               :schema,
               :version
             ]

    assert explanation.version == 1
    assert explanation.kind == :flow
    assert explanation.name == "explainable"
    assert explanation.description == "Exact inspection data"
    assert explanation.schema == schema
    assert explanation.output_schema == output_schema
    assert Enum.map(explanation.nodes, & &1.name) == ["alpha", "zeta"]
    refute inspect(explanation.nodes) =~ "provenance"
    assert explanation.dependencies == %{"alpha" => [], "zeta" => []}
    assert explanation.edges == []
    assert explanation.return == %{result: %{type: :result, node: "zeta", path: [:value]}}
    assert explanation.identity == identity
    refute Map.has_key?(explanation, :provenance)
  end

  test "returns sorted canonical edges" do
    assert {:ok, explanation} = Flow.explain(diamond_flow())

    assert explanation.edges == [
             %{from: "a", to: "b"},
             %{from: "a", to: "c"},
             %{from: "b", to: "d"},
             %{from: "c", to: "d"}
           ]
  end

  test "returns tagged validation errors without loading Action modules" do
    unloaded_action = unique_module("UnloadedIdentityAction")
    assert {:error, :nofile} = Code.ensure_loaded(unloaded_action)

    valid =
      Flow.new!(
        name: "unloaded_identity",
        nodes: [Node.new!(name: :unloaded, action: unloaded_action)],
        return: Ref.result(:unloaded)
      )

    for function <- [&Flow.dependencies/1, &Flow.explain/1, &Flow.semantic_identity/1] do
      assert {:ok, _value} = function.(valid)
      assert {:error, :nofile} = Code.ensure_loaded(unloaded_action)
    end

    invalid = %{valid | schema: Zoi.integer()}

    for function <- [&Flow.dependencies/1, &Flow.explain/1, &Flow.semantic_identity/1] do
      assert {:error, %InvalidInputError{message: message}} = function.(invalid)
      assert message == "schema must accept map-shaped action data"
    end
  end

  test "returns tagged invalid-input errors for non-Flow inspection subjects" do
    for function <- [&Flow.dependencies/1, &Flow.explain/1, &Flow.semantic_identity/1] do
      assert {:error, %InvalidInputError{}} = function.(:not_a_flow)
    end
  end

  test "generated Flow modules expose equal zero-arity delegates" do
    module = unique_module("InspectionDelegatesFlow")

    create_module(
      module,
      quote do
        use Jido.Flow, name: "inspection_delegates_flow"

        flow do
          step(:echo, unquote(EchoParamsAction), %{value: input(:value)})
          return(result(:echo))
        end
      end
    )

    assert module.dependencies() == Flow.dependencies(module.flow())
    assert module.explain() == Flow.explain(module.flow())
    assert module.semantic_identity() == Flow.semantic_identity(module.flow())
  end

  test "pins the deterministic SHA-256 preimage and UUIDv8 projection" do
    flow = identity_flow()
    canonical_identity_map = Flow.to_map(flow)

    expected_digest =
      {:jido_flow_identity, 1, canonical_identity_map}
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    assert {:ok, identity} = Flow.semantic_identity(flow)

    assert identity == %{
             version: 1,
             algorithm: :sha256,
             digest: expected_digest,
             uuid: identity.uuid
           }

    assert identity.digest == "f62c5891a3aab53896bcfde84156082887bda6b26c218510fee23638dbcad389"
    assert identity.digest =~ ~r/^[0-9a-f]{64}$/

    assert identity.uuid =~
             ~r/^[0-9a-f]{8}-[0-9a-f]{4}-8[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

    assert identity.uuid == "f62c5891-a3aa-8538-96bc-fde841560828"
  end

  test "ignores provenance, independent author order, and stored registry aliases" do
    original = independent_flow([:zeta, :alpha])
    reordered = independent_flow([:alpha, :zeta])

    provenance_changed = %{
      original
      | provenance: %{source: :other},
        nodes: Enum.map(original.nodes, &%{&1 | provenance: %{line: 99}})
    }

    assert Flow.semantic_identity(original) == Flow.semantic_identity(reordered)
    assert Flow.semantic_identity(original) == Flow.semantic_identity(provenance_changed)

    first_stored = Flow.to_map(original, format: :stored, actions: %{"echo" => EchoParamsAction})

    second_stored =
      Flow.to_map(original, format: :stored, actions: %{"mirror" => EchoParamsAction})

    assert {:ok, first_loaded} =
             Flow.from_map(first_stored,
               actions: %{"echo" => EchoParamsAction},
               schema: [],
               output_schema: []
             )

    assert {:ok, second_loaded} =
             Flow.from_map(second_stored,
               actions: %{"mirror" => EchoParamsAction},
               schema: [],
               output_schema: []
             )

    assert Flow.semantic_identity(first_loaded) == Flow.semantic_identity(second_loaded)
  end

  test "changes identity for every semantic field" do
    flow = semantic_mutation_flow()
    assert {:ok, original} = Flow.semantic_identity(flow)

    mutations = [
      %{flow | name: "changed_name"},
      %{flow | description: "changed description"},
      %{flow | schema: Zoi.object(%{value: Zoi.integer()})},
      %{flow | output_schema: Zoi.object(%{value: Zoi.integer()})},
      update_in(flow.nodes, fn [first, second] -> [%{first | action: Add}, second] end),
      update_in(flow.nodes, fn [first, second] ->
        [%{first | input: %{changed: Ref.value(true)}}, second]
      end),
      update_in(flow.nodes, fn [first, second] -> [first, %{second | deps: ["first"]}] end),
      %{flow | return: %{value: Ref.result(:second, :value)}}
    ]

    for mutation <- mutations do
      assert {:ok, changed} = Flow.semantic_identity(mutation)
      refute changed.digest == original.digest
      refute changed.uuid == original.uuid
    end
  end

  defp identity_flow do
    Flow.new!(
      name: "identity_fixture",
      description: "Pinned OTP 29 identity",
      nodes: [
        Node.new!(
          name: :echo,
          action: EchoParamsAction,
          input: %{value: Ref.input(:value)}
        )
      ],
      return: %{value: Ref.result(:echo, :value)}
    )
  end

  defp diamond_flow do
    Flow.new!(
      name: "identity_diamond",
      nodes: [
        Node.new!(name: :a, action: EchoParamsAction),
        Node.new!(name: :b, action: EchoParamsAction, input: Ref.result(:a)),
        Node.new!(name: :c, action: EchoParamsAction, deps: [:a]),
        Node.new!(
          name: :d,
          action: EchoParamsAction,
          input: %{left: Ref.result(:b), right: Ref.result(:c)}
        )
      ],
      return: Ref.result(:d)
    )
  end

  defp independent_flow(order) do
    nodes =
      Map.new(
        alpha: Node.new!(name: :alpha, action: EchoParamsAction),
        zeta: Node.new!(name: :zeta, action: EchoParamsAction)
      )

    Flow.new!(
      name: "independent_identity",
      nodes: Enum.map(order, &Map.fetch!(nodes, &1)),
      return: %{alpha: Ref.result(:alpha), zeta: Ref.result(:zeta)}
    )
  end

  defp semantic_mutation_flow do
    Flow.new!(
      name: "semantic_mutations",
      description: "Original",
      nodes: [
        Node.new!(
          name: :first,
          action: EchoParamsAction,
          input: %{value: Ref.input(:value)}
        ),
        Node.new!(name: :second, action: EchoParamsAction)
      ],
      return: %{value: Ref.result(:first, :value)}
    )
  end
end
