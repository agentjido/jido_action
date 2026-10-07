Code.require_file("../support/runtime.exs", __DIR__)
Code.require_file("../support/fuzz.exs", __DIR__)

defmodule JidoActionTest.Property.Storage.CodecContractTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Jido.{Expr, Flow}
  alias Jido.Flow.{Codec, Ref, Registry}
  alias JidoActionTest.Property.{Fuzz, Runtime}

  defmodule Child do
    use Jido.Flow, name: "property_stored_child"

    flow do
      step "echo", action: JidoActionTest.Property.Runtime.Emit, params: %{value: input(:value)}
      output result("echo")
    end
  end

  @tag contracts: ["STORE-001"]
  @tag contract_cases: [
         "STORE-001/step",
         "STORE-001/subflow",
         "STORE-001/choice",
         "STORE-001/map",
         "STORE-001/reduce",
         "STORE-001/iterate",
         "STORE-001/dispatch",
         "STORE-001/version-one",
         "STORE-001/version-two",
         "STORE-001/key-kinds",
         "STORE-001/step-wire-format"
       ]
  property "every component kind and both document versions preserve portable generated data" do
    check all(value <- portable(), scalar <- integer(), max_runs: 40) do
      assert_portability(value, scalar)
    end
  end

  @tag contracts: ["STORE-002", "FLOW-004"]
  @tag contract_cases: [
         "STORE-002/unknown",
         "STORE-002/wrong-kind",
         "STORE-002/atom-inertness",
         "STORE-002/executable-fields",
         "STORE-002/read-alias"
       ]
  property "unknown identifiers wrong Registry kinds and executable stored fields reject inertly" do
    check all(suffix <- integer(0..1_000_000), max_runs: 40) do
      identifier = "pbt_unregistered_#{suffix}"
      refute existing_atom?(identifier)

      flow =
        JidoActionTest.FlowBuilder.new!(
          name: "registry",
          components: [
            JidoActionTest.FlowComponent.step!(
              name: "work",
              action: Runtime.Emit,
              params: %{value: suffix}
            )
          ],
          output: Ref.result("work")
        )

      assert {:ok, document, registry} = Codec.encode(flow)
      action_id = get_in(document, ["components", Access.at(0), "action"])
      invalid = put_in(document, ["components", Access.at(0), "action"], identifier)
      assert {:error, %Flow.Error.InvalidDefinitionError{}} = Codec.decode(invalid, registry)
      refute existing_atom?(identifier)
      wrong = Registry.new!(Map.put(registry.entries, action_id, {:flow, Child}))
      assert {:error, _} = Codec.decode(document, wrong)

      for field <- ["body", "code", "callable", "run"] do
        invalid = put_in(document, ["components", Access.at(0), field], identifier)
        assert {:error, _} = Codec.decode(invalid, registry)
      end

      alias_registry = Registry.new!(Map.put(registry.entries, "old_emit", {:alias, action_id}))

      aliased = put_in(document, ["components", Access.at(0), "action"], "old_emit")
      assert {:ok, ^flow} = Codec.decode(aliased, alias_registry)
      assert {:ok, ^document} = Codec.encode(flow, alias_registry)
    end
  end

  @tag contracts: ["STORE-003"]
  @tag contract_cases: [
         "STORE-003/root",
         "STORE-003/version",
         "STORE-003/utf8",
         "STORE-003/depth",
         "STORE-003/width"
       ]
  property "malformed envelopes unsupported versions and boundary safety limits reject" do
    check all(extra <- integer(1..5), max_runs: 10) do
      flow =
        JidoActionTest.FlowBuilder.new!(
          name: "limits",
          components: [JidoActionTest.FlowComponent.step!(name: "work", action: Runtime.Emit)],
          output: %{}
        )

      assert {:ok, document, registry} = Codec.encode(flow)
      deep = Enum.reduce(1..(100 + extra), 0, fn _, value -> [value] end)

      for invalid <- [
            nil,
            [],
            Map.put(document, "version", 2 + extra),
            Map.put(document, "output", <<255>>),
            Map.put(document, "output", deep),
            Map.put(document, "output", List.duplicate(0, 10_000 + extra))
          ] do
        assert {:error, error} = Codec.decode(invalid, registry)
        assert is_exception(error)
        assert {:error, %Flow.Error.Invalid{errors: [_ | _]}} = Codec.diagnose(invalid, registry)
      end
    end
  end

  # This expected document is written from the stored contract, not Codec.encode/2.
  # It can detect matching reader/writer mistakes that a round trip cannot find.
  defp assert_step_wire_format(value) do
    registry =
      Registry.new!(%{
        "actions/emit" => {:action, Runtime.Emit},
        "schemas/empty" => {:schema, []},
        "atoms/value" => {:atom, :value}
      })

    flow =
      JidoActionTest.FlowBuilder.new!(
        name: "wire_oracle",
        components: [
          JidoActionTest.FlowComponent.step!(
            name: "work",
            action: Runtime.Emit,
            params: %{value: value}
          )
        ],
        output: Ref.result("work")
      )

    document = %{
      "type" => "jido.flow",
      "version" => 1,
      "name" => "wire_oracle",
      "description" => nil,
      "schema" => "schemas/empty",
      "output_schema" => "schemas/empty",
      "components" => [
        %{
          "kind" => "step",
          "name" => "work",
          "action" => "actions/emit",
          "params" => %{
            "$type" => "map",
            "entries" => [
              %{"key" => %{"$type" => "atom", "id" => "atoms/value"}, "value" => value}
            ]
          },
          "needs" => [],
          "meta" => %{"$type" => "map", "entries" => []}
        }
      ],
      "output" => %{"$ref" => %{"source" => "result", "component" => "work", "path" => []}}
    }

    assert Codec.encode(flow, registry) == {:ok, document}
    assert Codec.decode(JSON.decode!(JSON.encode!(document)), registry) == {:ok, flow}
  end

  defp all_components(value) do
    params = %{"key" => value, 1 => value, :value => value}

    JidoActionTest.FlowBuilder.new!(
      name: "stored",
      components: [
        JidoActionTest.FlowComponent.step!(name: "step", action: Runtime.Emit, params: params),
        JidoActionTest.FlowComponent.subflow!(
          name: "child",
          flow: Child,
          params: params,
          needs: ["step"]
        ),
        JidoActionTest.FlowComponent.choice!(
          name: "choice",
          options: [
            JidoActionTest.FlowComponent.option!(
              name: "yes",
              condition: Expr.new!(:==, [1, 1]),
              action: Runtime.Emit,
              params: params
            )
          ],
          fallback: JidoActionTest.FlowComponent.fallback!(action: Runtime.Emit, params: params)
        ),
        JidoActionTest.FlowComponent.map!(
          name: "map",
          collection: [value],
          action: Runtime.Emit,
          params: %{value: Ref.item()}
        ),
        JidoActionTest.FlowComponent.reduce!(
          name: "reduce",
          collection: [value],
          initial: %{},
          action: Runtime.Emit,
          params: params
        ),
        JidoActionTest.FlowComponent.iterate!(
          name: "iterate",
          action: Runtime.Emit,
          params: params,
          state: JidoActionTest.FlowComponent.state!(initial: %{}, update: %{}),
          completion: Expr.new!(:==, [1, 1]),
          max_iterations: 1
        ),
        JidoActionTest.FlowComponent.dispatch!(
          name: "dispatch",
          decision: Runtime.Emit,
          expander: Runtime.Emit,
          params: params,
          needs: ["step", "child", "choice", "map", "reduce", "iterate"]
        )
      ],
      output: Ref.result("dispatch")
    )
  end

  defp portable do
    scalar =
      one_of([integer(-100..100), string(:alphanumeric, max_length: 8), boolean(), constant(nil)])

    tree(scalar, fn inner ->
      one_of([list_of(inner, max_length: 3), map(inner, &%{"nested" => &1})])
    end)
  end

  defp existing_atom?(value) do
    _atom = String.to_existing_atom(value)
    true
  rescue
    ArgumentError -> false
  end

  defp assert_portability(value, scalar) do
    assert_step_wire_format(scalar)
    flow = all_components(value)
    assert {:ok, document, registry} = Codec.encode(flow)
    assert document["version"] == 2

    assert Enum.map(document["components"], & &1["kind"]) ==
             ["choice", "iterate", "map", "reduce", "step", "subflow", "dispatch"]

    assert {:ok, ^flow} = Codec.decode(JSON.decode!(JSON.encode!(document)), registry)
    assert {:ok, ^flow} = Codec.diagnose(document, registry)

    assert {:ok, ^document} = Codec.encode(flow, registry)
  end

  @tag :fuzz
  @tag max_runs: 300, max_run_time: 300_000, timeout: 900_000
  @tag contracts: ["FLOW-003", "FLOW-004", "STORE-002", "STORE-003"]
  @tag contract_cases: [
         "FLOW-003/fuzz-stored-cycle",
         "STORE-002/fuzz-unknown",
         "STORE-003/fuzz-depth",
         "STORE-003/fuzz-width",
         "STORE-003/fuzz-nodes"
       ]
  test "fuzz: selected document mutations reject without resolving unknown atoms", context do
    faults = ~w(root version utf8 depth width nodes kind action needs cycle output code)

    generator =
      fixed_map(%{
        "fault" => member_of(faults),
        "value" => integer(),
        "extra" => integer(1..10),
        "suffix" => string(:alphanumeric, max_length: 30)
      })

    examples =
      for fault <- faults,
          do: %{"fault" => fault, "value" => 1, "extra" => 1, "suffix" => "fixed"}

    Fuzz.check(
      "codec_mutations",
      generator,
      Map.to_list(context) ++ [examples: examples],
      fn sample ->
        identifier = "fuzz_unknown_codec_" <> sample["suffix"]
        refute existing_atom?(identifier)

        flow =
          JidoActionTest.FlowBuilder.new!(
            name: "mutated",
            components: [
              JidoActionTest.FlowComponent.step!(
                name: "work",
                action: Runtime.Emit,
                params: %{value: sample["value"]}
              )
            ],
            output: Ref.result("work")
          )

        assert {:ok, document, registry} = Codec.encode(flow)
        extra = sample["extra"]

        invalid =
          case sample["fault"] do
            "root" ->
              [document]

            "version" ->
              Map.put(document, "version", 2 + extra)

            "utf8" ->
              Map.put(document, "output", <<255, extra>>)

            "depth" ->
              Map.put(
                document,
                "output",
                Enum.reduce(1..(100 + extra), 0, fn _, acc -> [acc] end)
              )

            "width" ->
              Map.put(document, "output", List.duplicate(0, 10_000 + extra))

            "nodes" ->
              Map.put(document, "output", List.duplicate(List.duplicate(0, 1_000), 100 + extra))

            "kind" ->
              put_in(document, ["components", Access.at(0), "kind"], identifier)

            "action" ->
              put_in(document, ["components", Access.at(0), "action"], identifier)

            "needs" ->
              put_in(document, ["components", Access.at(0), "needs"], [identifier])

            "cycle" ->
              put_in(document, ["components", Access.at(0), "needs"], ["work"])

            "output" ->
              Map.put(document, "output", nil)

            "code" ->
              put_in(document, ["components", Access.at(0), "code"], "send(self(), :executed)")
          end

        Runtime.with_context(fn runtime ->
          assert {:error, error} = Codec.decode(invalid, registry)
          assert is_exception(error)

          assert {:error, %Flow.Error.Invalid{errors: [_ | _]}} =
                   Codec.diagnose(invalid, registry)

          Runtime.assert_calls(runtime, [])
          refute_received :executed
        end)

        refute existing_atom?(identifier)
        [sample["fault"]]
      end
    )
  end

  @tag :fuzz
  @tag max_runs: 300, max_run_time: 300_000, timeout: 900_000
  @tag contracts: ["STORE-001", "STORE-002", "FLOW-005"]
  @tag contract_cases: [
         "STORE-001/fuzz-all-kinds",
         "STORE-001/fuzz-versions",
         "STORE-001/fuzz-wire-oracle",
         "STORE-002/fuzz-alias",
         "FLOW-005/fuzz-literal-reference"
       ]
  test "fuzz: portable trees retain versions aliases and reference meaning", context do
    scalar = one_of([integer(), string(:alphanumeric, max_length: 80), boolean(), constant(nil)])

    values =
      tree(scalar, fn inner ->
        one_of([list_of(inner, max_length: 6), map(inner, &%{"nested" => &1})])
      end)

    generator = fixed_map(%{"value" => values, "scalar" => integer()})

    Fuzz.check("codec_portability", generator, Map.to_list(context), fn sample ->
      assert_portability(sample["value"], sample["scalar"])
      reference = Ref.input(:value)

      flows =
        for expression <- [reference, Ref.to_map(reference)] do
          JidoActionTest.FlowBuilder.new!(
            name: "identity",
            components: [
              JidoActionTest.FlowComponent.step!(
                name: "work",
                action: Runtime.Emit,
                params: %{value: sample["value"]}
              )
            ],
            output: %{value: expression}
          )
        end

      [referenced, literal] = flows
      refute Flow.semantic_identity(referenced) == Flow.semantic_identity(literal)

      for flow <- flows do
        assert {:ok, document, registry} = Codec.encode(flow)
        id = get_in(document, ["components", Access.at(0), "action"])
        aliased = put_in(document, ["components", Access.at(0), "action"], "legacy_emit")
        registry = Registry.new!(Map.put(registry.entries, "legacy_emit", {:alias, id}))
        assert {:ok, ^flow} = Codec.decode(aliased, registry)
        assert {:ok, ^document} = Codec.encode(flow, registry)
        assert {:ok, decoded} = Codec.decode(JSON.decode!(JSON.encode!(document)), registry)
        assert Flow.semantic_identity(decoded) == Flow.semantic_identity(flow)
      end

      ["all-components", "both-versions", "alias", "reference-and-literal"]
    end)
  end
end
