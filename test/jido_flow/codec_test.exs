defmodule Jido.Flow.CodecTest do
  use ExUnit.Case, async: true

  alias Jido.Action.Error.InvalidInputError
  alias Jido.Flow
  alias Jido.Flow.Choice
  alias Jido.Flow.Codec
  alias Jido.Flow.Condition
  alias Jido.Flow.Iterate
  alias Jido.Flow.Map, as: FlowMap
  alias Jido.Flow.Reduce
  alias Jido.Flow.Ref
  alias Jido.Flow.Registry
  alias Jido.Flow.Step
  alias Jido.Flow.Subflow
  alias JidoActionTest.FlowFixtures.NestedFlow
  alias JidoActionTest.TestActions.{Add, Multiply}

  test "JSON bytes round trip to the equal canonical Flow" do
    flow = mixed_flow()
    registry = registry()

    assert {:ok, document} = Codec.encode(flow, registry)
    assert document["version"] == 1

    assert Enum.map(document["components"], & &1["kind"]) ==
             ["step", "subflow", "choice", "map", "reduce", "iterate"]

    json = Jason.encode!(document)
    decoded_document = Jason.decode!(json)

    assert {:ok, decoded} = Codec.decode(decoded_document, registry)
    assert decoded == flow
    assert {:ok, ^document} = Codec.encode(decoded, registry)
  end

  test "the decoder rejects an unsupported version and missing component kinds" do
    {:ok, document} = Codec.encode(mixed_flow(), registry())

    assert {:error, %InvalidInputError{}} =
             Codec.decode(%{document | "version" => 99}, registry())

    [first | rest] = document["components"]
    invalid = %{document | "components" => [Map.delete(first, "kind") | rest]}
    assert {:error, %InvalidInputError{}} = Codec.decode(invalid, registry())
  end

  test "Action and Flow identifiers have distinct trusted kinds" do
    flow =
      Flow.new!(
        name: "one_subflow",
        components: [Subflow.new!(name: "child", flow: NestedFlow)],
        output: Ref.result("child")
      )

    wrong_registry =
      Registry.new!(%{
        "targets/child" => {:action, NestedFlow},
        "schemas/empty" => {:schema, []}
      })

    assert {:error, %InvalidInputError{}} = Codec.encode(flow, wrong_registry)

    document = %{
      "type" => "jido.flow",
      "version" => 1,
      "name" => "one_subflow",
      "description" => nil,
      "schema" => "schemas/empty",
      "output_schema" => "schemas/empty",
      "components" => [
        %{
          "kind" => "subflow",
          "name" => "child",
          "flow" => "targets/child",
          "params" => %{"$type" => "map", "entries" => []},
          "after" => [],
          "meta" => %{"$type" => "map", "entries" => []}
        }
      ],
      "output" => %{
        "$ref" => %{"source" => "result", "component" => "child", "path" => []}
      }
    }

    assert {:error, %InvalidInputError{}} = Codec.decode(document, wrong_registry)
  end

  test "unknown module text is never resolved without a Registry entry" do
    {:ok, document} = Codec.encode(mixed_flow(), registry())
    [step | rest] = document["components"]
    unknown_identifier = "untrusted/action/#{System.unique_integer([:positive])}"
    document = %{document | "components" => [%{step | "action" => unknown_identifier} | rest]}

    refute existing_atom?(unknown_identifier)
    assert {:error, %InvalidInputError{}} = Codec.decode(document, registry())
    refute existing_atom?(unknown_identifier)
  end

  defp mixed_flow do
    iterate_state =
      Iterate.State.new!(
        schema: [],
        initial: %{count: 0},
        update: %{count: Ref.body_result(:value)}
      )

    Flow.new!(
      name: "mixed_codec_flow",
      description: "All canonical component records",
      components: [
        Step.new!(
          name: "load",
          action: Add,
          params: %{value: Ref.input(:value), amount: 1},
          meta: %{owner: "codec"}
        ),
        Subflow.new!(
          name: "child",
          flow: NestedFlow,
          params: %{value: Ref.result("load", :value)},
          after: ["load"]
        ),
        Choice.new!(
          name: "route",
          options: [
            Choice.Option.new!(
              name: "add",
              condition: Condition.eq(Ref.input(:kind), :go),
              action: Add,
              params: %{value: Ref.result("child", :value), amount: 1}
            )
          ],
          fallback: Choice.Fallback.new!(action: Multiply, params: %{value: 1, amount: 1})
        ),
        FlowMap.new!(
          name: "mapped",
          collection: Ref.input(:items),
          action: Add,
          params: %{value: Ref.item(:value), amount: 1},
          on_error: :collect_errors
        ),
        Reduce.new!(
          name: "reduced",
          collection: Ref.result("mapped"),
          initial: %{value: 1},
          action: Multiply,
          params: %{value: Ref.accumulator(:value), amount: Ref.item(:value)}
        ),
        Iterate.new!(
          name: "loop",
          action: Add,
          params: %{value: Ref.state(:count), amount: 1},
          state: iterate_state,
          completion: Condition.gte(Ref.state(:count), 1),
          max_iterations: 1,
          after: ["route", "reduced"],
          meta: %{debug: true}
        )
      ],
      output: Ref.result("loop")
    )
  end

  defp registry do
    Registry.new!(%{
      "actions/add" => {:action, Add},
      "actions/multiply" => {:action, Multiply},
      "flows/nested" => {:flow, NestedFlow},
      "schemas/empty" => {:schema, []},
      "atoms/amount" => {:atom, :amount},
      "atoms/count" => {:atom, :count},
      "atoms/debug" => {:atom, :debug},
      "atoms/go" => {:atom, :go},
      "atoms/items" => {:atom, :items},
      "atoms/kind" => {:atom, :kind},
      "atoms/owner" => {:atom, :owner},
      "atoms/value" => {:atom, :value}
    })
  end

  defp existing_atom?(value) do
    _atom = String.to_existing_atom(value)
    true
  rescue
    ArgumentError -> false
  end
end
