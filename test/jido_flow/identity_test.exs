defmodule JidoActionTest.Flow.IdentityTest do
  use JidoActionTest.Case, async: true

  alias Jido.Action.Error.InvalidInputError
  alias Jido.Flow
  alias Jido.Flow.{Choice, Condition, Identity, Node, Reduce, Ref}
  alias Jido.Flow.Map, as: FlowMap
  alias JidoActionTest.TestActions.{Add, EchoParamsAction, Multiply}

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
          step("echo",
            action: unquote(EchoParamsAction),
            params: %{value: input(:value)}
          )
        end
      end
    )

    assert module.dependencies() == Flow.dependencies(module.flow())
    assert module.explain() == Flow.explain(module.flow())
    assert module.semantic_identity() == Flow.semantic_identity(module.flow())
    assert module.validate() == Flow.validate(module.flow())
    assert module.validate_executable() == Flow.validate_executable(module.flow())
    assert function_exported?(module, :to_stored_map, 1)
    assert function_exported?(module, :to_stored_map, 2)
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

    assert identity.digest == "78a86308b9d2ce0ef8735949f653875e8f11afeb40c37d6deca2ca7484711b91"
    assert identity.digest =~ ~r/^[0-9a-f]{64}$/

    assert identity.uuid =~
             ~r/^[0-9a-f]{8}-[0-9a-f]{4}-8[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

    assert identity.uuid == "78a86308-b9d2-8e0e-b873-5949f653875e"
  end

  test "creates domain-separated stable UUIDv8 item identities" do
    flow_digest = String.duplicate("a", 64)

    expected =
      {:jido_flow_item_identity, 1, flow_digest, "enrich", 0}
      |> Identity.hash_term()
      |> Identity.uuid_v8()

    assert Identity.item_uuid(flow_digest, "enrich", 0) == expected
    assert Identity.item_uuid(flow_digest, "enrich", 0) == expected

    assert Identity.item_uuid(flow_digest, "enrich", 0) !=
             Identity.step_uuid(flow_digest, "enrich")

    refute Identity.item_uuid(flow_digest, "enrich", 0) ==
             Identity.item_uuid(String.duplicate("b", 64), "enrich", 0)

    refute Identity.item_uuid(flow_digest, "enrich", 0) ==
             Identity.item_uuid(flow_digest, "other", 0)

    refute Identity.item_uuid(flow_digest, "enrich", 0) ==
             Identity.item_uuid(flow_digest, "enrich", 1)

    assert expected =~
             ~r/^[0-9a-f]{8}-[0-9a-f]{4}-8[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
  end

  test "makes every Map and Reduce semantic field part of Flow and item identity" do
    flow = map_reduce_identity_flow()
    {:ok, base_identity} = Flow.semantic_identity(flow)

    mutations = [
      update_map_reduce(flow, "enrich", &%{&1 | action: Multiply}),
      update_map_reduce(flow, "enrich", &%{&1 | collection: Ref.input(:other_items)}),
      update_map_reduce(flow, "enrich", &%{&1 | input: %{item: Ref.item(:value)}}),
      update_map_reduce(flow, "enrich", &%{&1 | on_error: :collect_errors}),
      update_map_reduce(flow, "enrich", &%{&1 | deps: ["source"]}),
      update_map_reduce(flow, "summarize", &%{&1 | action: EchoParamsAction}),
      update_map_reduce(flow, "summarize", &%{&1 | collection: Ref.value([]), deps: []}),
      update_map_reduce(flow, "summarize", &%{&1 | initial: Ref.value(1)}),
      update_map_reduce(flow, "summarize", &%{&1 | input: %{acc: Ref.accumulator(:total)}}),
      update_map_reduce(flow, "summarize", &%{&1 | deps: ["enrich", "source"]})
    ]

    for mutated <- mutations do
      assert {:ok, identity} = Flow.semantic_identity(mutated)
      refute identity.digest == base_identity.digest

      refute Identity.item_uuid(identity.digest, "enrich", 0) ==
               Identity.item_uuid(base_identity.digest, "enrich", 0)
    end

    provenance_changed =
      flow
      |> update_map_reduce("enrich", &%{&1 | provenance: %{line: 200}})
      |> update_map_reduce("summarize", &%{&1 | provenance: %{line: 300}})

    assert Flow.semantic_identity(provenance_changed) == {:ok, base_identity}
  end

  test "ignores provenance and independent author order" do
    original = independent_flow([:zeta, :alpha])
    reordered = independent_flow([:alpha, :zeta])

    provenance_changed = %{
      original
      | provenance: %{source: :other},
        nodes: Enum.map(original.nodes, &%{&1 | provenance: %{line: 99}})
    }

    assert Flow.semantic_identity(original) == Flow.semantic_identity(reordered)
    assert Flow.semantic_identity(original) == Flow.semantic_identity(provenance_changed)
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

  test "makes Choice order semantic while ignoring Choice provenance" do
    flow = choice_identity_flow([:first, :second])
    reordered = choice_identity_flow([:second, :first])

    provenance_changed = %{
      flow
      | nodes:
          Enum.map(flow.nodes, fn
            %Choice{} = choice -> %{choice | provenance: %{source: :other}}
            node -> node
          end)
    }

    assert {:ok, identity} = Flow.semantic_identity(flow)
    assert {:ok, reordered_identity} = Flow.semantic_identity(reordered)
    assert {:ok, provenance_identity} = Flow.semantic_identity(provenance_changed)

    refute identity.digest == reordered_identity.digest
    assert identity == provenance_identity
  end

  test "inspects Choice as one ordered node with all direct predecessors" do
    flow =
      Flow.new!(
        name: "choice_inspection",
        nodes: [
          Node.new!(name: :left, action: EchoParamsAction),
          Node.new!(name: :right, action: EchoParamsAction),
          Choice.new!(
            name: :route,
            options: [
              [
                name: :left_option,
                condition: Condition.eq(Ref.result(:left, :value), 1),
                action: Add
              ],
              [
                name: :right_option,
                condition: Condition.eq(Ref.result(:right, :value), 2),
                action: Multiply
              ]
            ],
            fallback: [action: Add, input: %{value: Ref.result(:left, :value)}]
          )
        ],
        return: Ref.result(:route)
      )

    assert {:ok, %{"route" => ["left", "right"]}} = Flow.dependencies(flow)
    assert {:ok, explanation} = Flow.explain(flow)

    assert [_, _, %{kind: :choice, name: "route", options: options, fallback: fallback}] =
             explanation.nodes

    assert Enum.map(options, & &1.name) == ["left_option", "right_option"]
    assert fallback.name == :fallback
    refute inspect(explanation.nodes) =~ "provenance"
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

  defp map_reduce_identity_flow do
    Flow.new!(
      name: "map_reduce_identity",
      nodes: [
        Node.new!(name: :source, action: EchoParamsAction),
        FlowMap.new!(
          name: :enrich,
          collection: Ref.input(:items),
          action: Add,
          input: %{item: Ref.item()}
        ),
        Reduce.new!(
          name: :summarize,
          collection: Ref.result(:enrich),
          initial: Ref.value(0),
          action: Multiply,
          input: %{acc: Ref.accumulator(), item: Ref.item()}
        )
      ],
      return: Ref.result(:summarize)
    )
  end

  defp update_map_reduce(flow, name, update) do
    %{
      flow
      | nodes:
          Enum.map(flow.nodes, fn element ->
            if element.name == name, do: update.(element), else: element
          end)
    }
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

  defp choice_identity_flow(order) do
    options = %{
      first: [
        name: :first,
        condition: Condition.eq(Ref.input(:kind), :first),
        action: Add,
        input: %{value: Ref.value(1), amount: Ref.value(1)}
      ],
      second: [
        name: :second,
        condition: Condition.eq(Ref.input(:kind), :second),
        action: Multiply,
        input: %{value: Ref.value(2), by: Ref.value(2)}
      ]
    }

    Flow.new!(
      name: "choice_identity",
      nodes: [
        Choice.new!(
          name: :route,
          options: Enum.map(order, &Map.fetch!(options, &1)),
          fallback: [action: Add, input: %{value: Ref.value(3), amount: Ref.value(1)}]
        )
      ],
      return: Ref.result(:route)
    )
  end
end
