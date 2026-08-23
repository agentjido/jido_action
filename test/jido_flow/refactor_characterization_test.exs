defmodule Jido.Flow.RefactorCharacterizationTest do
  use ExUnit.Case, async: true

  alias Jido.Flow
  alias Jido.Flow.{Builder, Node, Ref, Registry}
  alias JidoTest.TestActions.{Add, Multiply}

  test "keeps the documented Flow facade available without freezing private exports" do
    Code.ensure_loaded!(Flow)

    for {name, arity} <- [
          new: 1,
          new!: 1,
          dependencies: 1,
          explain: 1,
          from_stored_map: 2,
          semantic_identity: 1,
          to_map: 1,
          to_map: 2,
          to_stored_map: 2,
          to_stored_map: 3,
          validate: 1,
          validate_executable: 1
        ] do
      assert function_exported?(Flow, name, arity)
    end

    assert macro_exported?(Flow, :__using__, 1)
  end

  test "keeps DSL, Builder, and stored-map authoring semantically equal" do
    dsl_module = unique_module()

    Module.create(
      dsl_module,
      quote do
        use Jido.Flow, name: "surface_parity"

        flow do
          step("seed",
            action: unquote(Add),
            params: %{value: input(:value), amount: value(1)}
          )

          choice "route" do
            option("positive",
              condition: select(result("seed"), [:value]) > 0,
              action: unquote(Add),
              params: %{value: select(result("seed"), [:value]), amount: value(1)}
            )

            otherwise(
              action: unquote(Multiply),
              params: %{value: select(result("seed"), [:value]), amount: value(2)}
            )
          end

          map("mapped",
            collection: input(:items),
            action: unquote(Multiply),
            params: %{value: item(), amount: select(result("route"), [:value])}
          )

          reduce("total",
            collection: result("mapped"),
            initial: %{value: value(0)},
            action: unquote(Add),
            params: %{value: accumulator(:value), amount: item(:value)}
          )

          iterate "count" do
            state([], initial: %{value: select(result("total"), [:value])})
            action(unquote(Add))
            params(%{value: state(:value), amount: value(1)})
            update(%{value: body_result(:value)})
            repeat(2)
          end

          output(result("count"))
        end
      end,
      Macro.Env.location(__ENV__)
    )

    builder =
      Builder.new(name: "surface_parity")
      |> Builder.step("seed", Add, %{value: Builder.input(:value), amount: Builder.value(1)})
      |> Builder.choice(
        "route",
        [
          Builder.option(
            "positive",
            Builder.gt(Builder.result("seed", :value), Builder.value(0)),
            Add,
            %{value: Builder.result("seed", :value), amount: Builder.value(1)}
          )
        ],
        Builder.fallback(Multiply, %{
          value: Builder.result("seed", :value),
          amount: Builder.value(2)
        })
      )
      |> Builder.map("mapped", Builder.input(:items), Multiply, %{
        value: Builder.item(),
        amount: Builder.result("route", :value)
      })
      |> Builder.reduce(
        "total",
        Builder.result("mapped"),
        %{value: Builder.value(0)},
        Add,
        %{value: Builder.accumulator(:value), amount: Builder.item(:value)}
      )
      |> Builder.iterate(
        "count",
        Add,
        %{value: Builder.state(:value), amount: Builder.value(1)},
        %{
          schema: [],
          initial: %{value: Builder.result("total", :value)},
          update: %{value: Builder.body_result(:value)}
        },
        repeat: 2
      )
      |> Builder.return(Builder.result("count"))

    assert {:ok, built} = Builder.build(builder)
    assert Flow.to_map(dsl_module.flow()) == Flow.to_map(built)

    assert {:ok, stored} = Flow.to_stored_map(built, registry())

    assert {:ok, restored} =
             stored |> Jason.encode!() |> Jason.decode!() |> Flow.from_stored_map(registry())

    assert Flow.to_map(restored) == Flow.to_map(built)
  end

  test "keeps the representative stored-map shape stable" do
    flow =
      Flow.new!(
        name: "codec_characterization",
        description: "stable",
        nodes: [
          Node.new!(
            name: "add",
            action: Add,
            input: %{
              :amount => Ref.value(2),
              "value" => Ref.input(:value)
            },
            provenance: %{line: 7}
          )
        ],
        return: Ref.result("add", :value),
        provenance: %{source: "test"}
      )

    assert {:ok, stored} = Flow.to_stored_map(flow, registry(), provenance: true)

    assert stored == %{
             "type" => "flow",
             "version" => 1,
             "name" => "codec_characterization",
             "description" => "stable",
             "input_schema" => "schema/empty/v1",
             "output_schema" => "schema/empty/v1",
             "nodes" => [
               %{
                 "name" => "add",
                 "action" => "action/add/v1",
                 "input" => %{
                   "type" => "map",
                   "entries" => [
                     %{
                       "key" => %{"type" => "atom", "value" => "amount"},
                       "value" => %{"type" => "value", "value" => 2}
                     },
                     %{
                       "key" => %{"type" => "string", "value" => "value"},
                       "value" => %{
                         "type" => "input",
                         "path" => [%{"type" => "atom", "value" => "value"}]
                       }
                     }
                   ]
                 },
                 "deps" => [],
                 "provenance" => %{
                   "$type" => "map",
                   "entries" => [
                     %{
                       "key" => %{"type" => "atom", "value" => "line"},
                       "value" => 7
                     }
                   ]
                 }
               }
             ],
             "return" => %{
               "type" => "result",
               "node" => "add",
               "path" => [%{"type" => "atom", "value" => "value"}]
             },
             "provenance" => %{
               "$type" => "map",
               "entries" => [
                 %{
                   "key" => %{"type" => "atom", "value" => "source"},
                   "value" => "test"
                 }
               ]
             }
           }

    assert {:ok, restored} =
             stored |> Jason.encode!() |> Jason.decode!() |> Flow.from_stored_map(registry())

    assert Flow.to_map(restored, provenance: true) == Flow.to_map(flow, provenance: true)
  end

  test "keeps nested decoder and encoder error paths stable" do
    flow =
      Flow.new!(
        name: "codec_errors",
        nodes: [Node.new!(name: "add", action: Add, input: %{amount: Ref.value(2)})],
        return: Ref.result("add")
      )

    assert {:ok, stored} = Flow.to_stored_map(flow, registry())

    invalid =
      put_in(
        stored,
        ["nodes", Access.at(0), "input", "entries", Access.at(0), "value"],
        %{"type" => "unknown"}
      )

    assert {:error, error} = Flow.from_stored_map(invalid, registry())
    assert error.message == "unknown flow ref type: \"unknown\""
    assert error.details == %{type: "unknown", path: ["nodes", 0, "input", {:map_value, 0}]}

    invalid_provenance = %{flow | provenance: %{bad: self()}}

    assert {:error, error} =
             Flow.to_stored_map(invalid_provenance, registry(), provenance: true)

    assert error.message == "stored flow value is not JSON-safe"
    assert error.details.path == ["provenance", {:map_value, 0}]
  end

  defp registry do
    Registry.new!(%{
      "action/add/v1" => {:action, Add},
      "action/multiply/v1" => {:action, Multiply},
      "schema/empty/v1" => {:schema, []}
    })
  end

  defp unique_module do
    Module.concat(__MODULE__, "SurfaceParity#{System.unique_integer([:positive])}")
  end
end
