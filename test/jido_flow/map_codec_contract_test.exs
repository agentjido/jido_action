defmodule Jido.Flow.MapCodecContractTest do
  use ExUnit.Case, async: true

  alias Jido.Flow

  alias Jido.Flow.{
    Choice,
    Condition,
    Iterator,
    Node,
    Reduce,
    Ref,
    State
  }

  alias Jido.Flow.Map, as: FlowMap

  alias JidoTest.FlowFixtures
  alias JidoTest.TestActions.{Add, Multiply}

  test "round-trips every node, reference, condition, and data kind" do
    flow = complete_flow()

    assert {:ok, stored} = Flow.to_stored_map(flow, registry(), provenance: true)
    assert {:ok, restored} = Flow.from_stored_map(stored, registry())

    assert Flow.to_map(restored, provenance: true) == Flow.to_map(flow, provenance: true)

    assert stored["nodes"] |> Enum.map(& &1["kind"]) |> Enum.sort() ==
             [nil, "choice", "iterate", "map", "reduce"]

    seed = Enum.find(stored["nodes"], &(&1["name"] == "seed"))

    assert seed["input"]["entries"]
           |> Enum.any?(&(&1["key"]["type"] == "integer"))
  end

  test "validates writer options and public subjects without raising" do
    flow = complete_flow()

    for {opts, message} <- [
          {:invalid, "flow map options must be a keyword list"},
          {[provenance: true, provenance: false], "duplicate flow map option"},
          {[unknown: true], "unknown flow map option"}
        ] do
      assert {:error, error} = Flow.to_stored_map(flow, registry(), opts)
      assert Exception.message(error) =~ message
    end

    assert {:error, error} = Flow.to_stored_map(:not_a_flow, registry())
    assert Exception.message(error) == "expected a Jido.Flow artifact"

    assert {:error, error} = Flow.to_stored_map(flow, :not_a_registry)
    assert Exception.message(error) == "stored flow requires a Jido.Flow.Registry"

    assert {:error, error} = Flow.from_stored_map([], registry())
    assert Exception.message(error) == "flow map must be a map"

    assert {:error, error} = Flow.from_stored_map(base_stored(), :not_a_registry)
    assert Exception.message(error) == "stored flow requires a Jido.Flow.Registry"
  end

  test "returns structured errors for malformed root and node records" do
    stored = base_stored()

    invalid = [
      {Map.delete(stored, "version"), "flow map version is required"},
      {Map.delete(stored, "type"), "flow map type is required"},
      {Map.put(stored, "type", "action"), "flow map type must be flow"},
      {Map.put(stored, "nodes", :bad), "flow nodes must be a list"},
      {Map.put(stored, "nodes", [%{} | :tail]), "flow nodes must be a list"},
      {Map.put(stored, "nodes", [:bad]), "flow node must be a map"},
      {put_in(stored, ["nodes", Access.at(0), "kind"], "unknown"), "unknown flow node kind"},
      {put_in(stored, ["nodes", Access.at(0), "deps"], :bad), "flow node deps must be a list"},
      {put_in(stored, ["nodes", Access.at(0), "deps"], ["one" | :tail]),
       "flow node deps must be a list"}
    ]

    for {candidate, message} <- invalid do
      assert_error(candidate, message)
    end
  end

  test "keeps canonical validation paths after stored-map decoding" do
    invalid = put_in(base_stored(), ["nodes", Access.at(0), "name"], nil)

    assert {:error, error} = Flow.from_stored_map(invalid, registry())
    assert error.message == "node name must be a non-empty string or atom"
    assert error.details == %{path: [:nodes, 0]}
  end

  test "returns structured errors for malformed Choice records" do
    stored = stored_with(choice_record())

    invalid = [
      {put_in(stored, ["nodes", Access.at(0), "options"], :bad), "choice options must be a list"},
      {put_in(stored, ["nodes", Access.at(0), "options"], [choice_option() | :tail]),
       "choice options must be a list"},
      {put_in(stored, ["nodes", Access.at(0), "options"], [:bad]), "choice option must be a map"},
      {put_in(stored, ["nodes", Access.at(0), "fallback"], :bad),
       "choice fallback must be a map"},
      {put_in(stored, ["nodes", Access.at(0), "fallback", "name"], "other"),
       "choice fallback name must be fallback"},
      {put_in(
         stored,
         ["nodes", Access.at(0), "options", Access.at(0), "condition"],
         :bad
       ), "choice condition must be a map"},
      {put_in(
         stored,
         ["nodes", Access.at(0), "options", Access.at(0), "condition", "operator"],
         "bad"
       ), "unsupported choice condition operator"},
      {put_in(
         stored,
         ["nodes", Access.at(0), "options", Access.at(0), "condition", "operands"],
         :bad
       ), "choice condition operands must be a list"},
      {put_in(
         stored,
         ["nodes", Access.at(0), "options", Access.at(0), "condition", "operands"],
         [value_ref(1) | :tail]
       ), "choice condition operands must be a list"}
    ]

    for {candidate, message} <- invalid do
      assert_error(candidate, message)
    end
  end

  test "returns structured errors for malformed collection and Iterator records" do
    map = stored_with(map_record())
    assert_error(put_in(map, ["nodes", Access.at(0), "on_error"], "ignore"), "map on_error")

    iterator = stored_with(iterator_record())

    invalid = [
      {put_in(iterator, ["nodes", Access.at(0), "state"], :bad), "iterator state must be a map"},
      {put_in(iterator, ["nodes", Access.at(0), "state", "kind"], "state"),
       "iterate state kind must be iterate_state"},
      {put_in(iterator, ["nodes", Access.at(0), "state", "version"], 2),
       "unsupported iterator state version"},
      {put_in(iterator, ["nodes", Access.at(0), "state", "schema"], "bad identifier!"),
       "invalid flow registry identifier"},
      {put_in(iterator, ["nodes", Access.at(0), "completion", "operands"], :bad),
       "choice condition operands must be a list"}
    ]

    for {candidate, message} <- invalid do
      assert_error(candidate, message)
    end
  end

  test "returns structured errors for malformed reference records" do
    invalid_refs = [
      {%{"type" => "unknown"}, "unknown flow ref type"},
      {%{"value" => 1}, "stored flow expression must be a tagged record"},
      {1, "stored flow expression must be a tagged record"},
      {%{"type" => "result", "node" => 1, "path" => []},
       "stored result ref node must be a binary"},
      {%{"type" => "input", "path" => :bad}, "flow ref path must be a list"},
      {%{"type" => "input", "path" => [typed_key("string", "ok") | :tail]},
       "flow ref path must be a list"},
      {%{"type" => "input", "path" => [:bad]}, "malformed flow path segment"},
      {%{"type" => "input", "path" => [typed_key("float", 1.0)]}, "malformed flow path segment"},
      {%{"type" => "iteration_index", "path" => [typed_key("integer", 0)]},
       "iteration index ref path must be empty"}
    ]

    for {ref, message} <- invalid_refs do
      assert_error(Map.put(base_stored(), "return", ref), message)
    end
  end

  test "returns structured errors for malformed tagged data" do
    invalid_data = [
      {%{"$type" => "unknown"}, "unknown encoded value type"},
      {%{"$type" => "atom", "value" => 1}, "encoded atom value must be a binary"},
      {%{"$type" => "map", "entries" => :bad}, "encoded map entries must be a list"},
      {%{"$type" => "map", "entries" => [%{} | :tail]}, "encoded map entries must be a list"},
      {%{"$type" => "map", "entries" => [:bad]}, "encoded map entry must be a map"},
      {%{"plain" => %{1 => "bad"}}, "stored plain data map contains a non-string key"},
      {[%{"$type" => "unknown"}], "unknown encoded value type"}
    ]

    for {data, message} <- invalid_data do
      assert_error(Map.put(base_stored(), "provenance", data), message)
    end

    duplicate = %{
      "$type" => "map",
      "entries" => [encoded_entry(:ready, 1), encoded_entry(:ready, 2)]
    }

    assert_error(Map.put(base_stored(), "provenance", duplicate), "duplicate key")
  end

  test "keeps expression and data codec boundary paths stable" do
    flow =
      Flow.new!(
        name: "nested_codec_error",
        nodes: [
          Node.new!(
            name: "node",
            action: Add,
            input: %{payload: Ref.value(%{items: [{:unsupported, 1}]})}
          )
        ],
        return: Ref.result("node")
      )

    assert {:error, encode_error} = Flow.to_stored_map(flow, registry())
    assert encode_error.message == "stored flow value is not JSON-safe"

    assert encode_error.details.path == [
             "nodes",
             0,
             "input",
             {:map_value, 0},
             "value",
             {:map_value, 0},
             0
           ]

    invalid_data = %{
      "$type" => "map",
      "entries" => [
        %{
          "key" => typed_key("string", "payload"),
          "value" => %{"$type" => "unknown"}
        }
      ]
    }

    invalid = Map.put(base_stored(), "return", %{"type" => "value", "value" => invalid_data})

    assert {:error, decode_error} = Flow.from_stored_map(invalid, registry())
    assert decode_error.message == "unknown encoded value type: \"unknown\""

    assert decode_error.details == %{
             type: "unknown",
             path: ["return", "value", {:map_value, 0}]
           }
  end

  defp complete_flow do
    nodes = [
      Node.new!(
        name: "seed",
        action: Add,
        input: %{
          :key => Ref.input(:key),
          "request" => Ref.context(["request", 0]),
          7 => Ref.value(%{:status => :ready, "items" => [1, true, nil]})
        },
        provenance: %{line: 1}
      ),
      Choice.new!(
        name: "route",
        options: [
          [
            name: "matched",
            condition:
              Condition.all([
                Condition.neq(Ref.input(:kind), Ref.value(:blocked)),
                Condition.not(Condition.eq(Ref.context(:disabled), Ref.value(true)))
              ]),
            action: Add,
            input: %{value: Ref.input(:value), amount: Ref.value(1)}
          ]
        ],
        fallback: [action: Multiply, input: %{value: Ref.input(:value), amount: Ref.value(2)}],
        provenance: %{line: 2}
      ),
      FlowMap.new!(
        name: "mapped",
        collection: Ref.input(:items),
        action: Multiply,
        input: %{value: Ref.item(), amount: Ref.item_index(), id: Ref.item_id()},
        on_error: :collect_errors,
        provenance: %{line: 3}
      ),
      Reduce.new!(
        name: "total",
        collection: Ref.result("mapped"),
        initial: %{value: Ref.value(0)},
        action: Add,
        input: %{value: Ref.accumulator(:value), amount: Ref.item(:value)},
        provenance: %{line: 4}
      ),
      Iterator.new!(
        name: "count",
        action: Add,
        input: %{
          value: Ref.state(:value),
          amount: Ref.iteration_index()
        },
        state:
          State.new!(
            schema: [],
            initial: %{value: Ref.result("total", :value)},
            update: %{value: Ref.body_result(:value)}
          ),
        completion: %Condition{
          operator: :gte,
          operands: [Ref.state(:value), Ref.value(10)]
        },
        max_iterations: 5,
        provenance: %{line: 5}
      )
    ]

    Flow.new!(
      name: "complete_codec",
      nodes: nodes,
      return: %{
        result: Ref.result("count", [:state, :value]),
        selected: Ref.context(:request)
      },
      provenance: %{source: :test}
    )
  end

  defp assert_error(candidate, message) do
    assert {:error, error} = Flow.from_stored_map(candidate, registry())
    assert Exception.message(error) =~ message
  end

  defp registry do
    FlowFixtures.storage_registry()
  end

  defp base_stored do
    %{
      "type" => "flow",
      "version" => 1,
      "name" => "stored",
      "description" => nil,
      "input_schema" => "schema/empty/v1",
      "output_schema" => "schema/empty/v1",
      "nodes" => [step_record()],
      "return" => result_ref("node")
    }
  end

  defp stored_with(record) do
    base_stored()
    |> Map.put("nodes", [record])
    |> Map.put("return", result_ref(record["name"]))
  end

  defp step_record do
    %{
      "name" => "node",
      "action" => "action/add/v1",
      "input" => expression_map([]),
      "deps" => []
    }
  end

  defp choice_record do
    %{
      "kind" => "choice",
      "name" => "choice",
      "options" => [choice_option()],
      "fallback" => %{
        "name" => "fallback",
        "action" => "action/multiply/v1",
        "input" => expression_map([])
      },
      "deps" => []
    }
  end

  defp choice_option do
    %{
      "name" => "yes",
      "condition" => %{
        "operator" => "eq",
        "operands" => [value_ref(1), value_ref(1)]
      },
      "action" => "action/add/v1",
      "input" => expression_map([])
    }
  end

  defp map_record do
    %{
      "kind" => "map",
      "name" => "mapped",
      "collection" => value_ref([]),
      "action" => "action/add/v1",
      "input" => expression_map([]),
      "on_error" => "fail_fast",
      "deps" => []
    }
  end

  defp iterator_record do
    %{
      "kind" => "iterate",
      "name" => "iterator",
      "action" => "action/add/v1",
      "input" => expression_map([]),
      "state" => %{
        "kind" => "iterate_state",
        "version" => 1,
        "schema" => "schema/empty/v1",
        "initial" => expression_map([]),
        "update" => %{"type" => "body_result", "path" => []}
      },
      "completion" => %{
        "operator" => "eq",
        "operands" => [value_ref(true), value_ref(true)]
      },
      "max_iterations" => 1,
      "deps" => []
    }
  end

  defp expression_map(entries), do: %{"type" => "map", "entries" => entries}
  defp result_ref(node), do: %{"type" => "result", "node" => node, "path" => []}
  defp value_ref(value), do: %{"type" => "value", "value" => value}
  defp typed_key(type, value), do: %{"type" => type, "value" => value}

  defp encoded_entry(key, value) do
    %{
      "key" => typed_key("atom", Atom.to_string(key)),
      "value" => value
    }
  end
end
