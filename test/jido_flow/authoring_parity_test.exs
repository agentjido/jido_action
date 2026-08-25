defmodule JidoActionTest.Flow.AuthoringParityTest do
  use JidoActionTest.Case, async: true

  alias Jido.Exec
  alias Jido.Flow
  alias Jido.Flow.{Builder, Iterator, Ref}
  alias JidoActionTest.FlowFixtures
  alias JidoActionTest.TestActions.{Add, Multiply}

  test "a complete DSL Flow stores, restores, and uses one execution engine" do
    module = create_complete_flow_module()
    flow = module.flow()

    assert [%{name: "mapped"}, %{name: "total"}, %{name: "count"}] =
             Flow.to_map(flow).nodes

    assert [%Iterator{state: %{update: %Ref{type: :body_result}}}] =
             Enum.filter(flow.nodes, &match?(%Iterator{}, &1))

    assert {:ok, stored} = module.to_stored_map(registry())
    assert stored["version"] == 1
    refute Map.has_key?(stored, "contracts")

    assert {:ok, restored} =
             stored |> Jason.encode!() |> Jason.decode!() |> Flow.from_stored_map(registry())

    assert Flow.to_map(restored) == Flow.to_map(flow)

    input = %{items: [%{value: 1}, %{value: 2}]}
    assert {:ok, %{iterations: 2, state: %{value: 8}} = expected} = Exec.run(restored, input)

    assert {:ok, execution} = Exec.start(restored, input)
    assert Exec.ready(execution) == ["mapped"]
    assert {:ok, execution} = Exec.continue(execution)
    assert Exec.status(execution) == :succeeded
    assert Exec.result(execution) == {:ok, expected}
  end

  test "DSL, Builder, and stored-map authoring produce equal Flow data and results" do
    module = create_surface_parity_module()

    builder =
      Builder.new(name: "surface_parity")
      |> Builder.step("seed", Add, %{
        value: Builder.input(:value),
        amount: Builder.value(1)
      })
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
    assert Flow.to_map(module.flow()) == Flow.to_map(built)

    assert {:ok, stored} = Flow.to_stored_map(built, registry())

    assert {:ok, restored} =
             stored |> Jason.encode!() |> Jason.decode!() |> Flow.from_stored_map(registry())

    assert Flow.to_map(restored) == Flow.to_map(built)

    results =
      Enum.map([module.flow(), built, restored], fn flow ->
        Exec.run(flow, %{value: 1, items: [1, 2]})
      end)

    assert [{:ok, %{iterations: 2, state: %{value: 11}}}] = Enum.uniq(results)
  end

  defp create_complete_flow_module do
    module = unique_module("CompleteStoredFlow")

    create_module(
      module,
      quote do
        use Jido.Flow, name: "complete_stored_flow"

        flow do
          map("mapped",
            collection: input(:items),
            action: unquote(Multiply),
            params: %{value: item(:value), amount: 2}
          )

          reduce "total" do
            collection(result("mapped"))
            initial(%{value: 0})
            action(unquote(Add))
            params(%{value: accumulator(:value), amount: item(:value)})
          end

          iterate "count" do
            state([], initial: %{value: select(result("total"), [:value])})
            action(unquote(Add))
            params(%{value: state(:value), amount: 1})
            repeat(2)
          end

          output(result("count"))
        end
      end
    )

    module
  end

  defp create_surface_parity_module do
    module = unique_module("SurfaceParity")

    create_module(
      module,
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
      end
    )

    module
  end

  defp registry, do: FlowFixtures.storage_registry()
end
