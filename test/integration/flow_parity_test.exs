defmodule Jido.Integration.FlowParityTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Exec
  alias Jido.Flow
  alias Jido.Flow.{Builder, Iterator, Ref}
  alias JidoTest.FlowFixtures
  alias JidoTest.TestActions.{Add, Multiply}

  test "a complete Spark Flow stores, restores, and uses one execution engine" do
    module = create_complete_flow_module()
    flow = module.flow()
    registry = registry()

    assert [%{name: "mapped"}, %{name: "total"}, %{name: "count"}] =
             Flow.to_map(flow).nodes

    assert [%Iterator{state: %{update: %Ref{type: :body_result}}}] =
             Enum.filter(flow.nodes, &match?(%Iterator{}, &1))

    assert {:ok, stored} = module.to_stored_map(registry)
    assert stored["version"] == 1
    refute Map.has_key?(stored, "contracts")

    json = Jason.encode!(stored)
    assert {:ok, restored} = json |> Jason.decode!() |> Flow.from_stored_map(registry)
    assert Flow.to_map(restored) == Flow.to_map(flow)

    input = %{items: [%{value: 1}, %{value: 2}]}
    assert {:ok, expected} = Exec.run(restored, input)
    assert %{iterations: 2, state: %{value: 8}} = expected

    assert {:ok, execution} = Exec.start(restored, input)
    assert Exec.ready(execution) == ["mapped"]
    assert {:ok, execution} = Exec.continue(execution)
    assert Exec.status(execution) == :succeeded
    assert Exec.result(execution) == {:ok, expected}
  end

  test "Builder and Spark use named result references with equal semantics" do
    module = create_step_flow_module()

    builder =
      Builder.new(name: "step_parity")
      |> Builder.step("added", Add, %{value: Builder.input(:value), amount: 1})
      |> Builder.step("doubled", Multiply, %{
        value: Builder.select(Builder.result("added"), [:value]),
        amount: 2
      })
      |> Builder.return(Builder.result("doubled"))

    assert {:ok, built} = Builder.build(builder)
    assert Flow.to_map(built) == Flow.to_map(module.flow())
    assert {:ok, %{value: 8}} = Exec.run(built, %{value: 3})
  end

  test "short-form and do/end Spark declarations use the same syntax path" do
    module = unique_module("MixedSparkForms")

    create_module(
      module,
      quote do
        use Jido.Flow, name: "mixed_forms"

        flow do
          step("short", action: unquote(Add), params: %{value: input(:value)})

          step "block" do
            action(unquote(Multiply))
            params(%{value: select(result("short"), [:value]), amount: 2})
          end
        end
      end
    )

    assert {:ok, %{value: 6}} = module.run(%{value: 2}, %{})
    assert {:ok, %{"short" => [], "block" => ["short"]}} = module.dependencies()
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

  defp create_step_flow_module do
    module = unique_module("StepParity")

    create_module(
      module,
      quote do
        use Jido.Flow, name: "step_parity"

        flow do
          step("added",
            action: unquote(Add),
            params: %{value: input(:value), amount: 1}
          )

          step("doubled",
            action: unquote(Multiply),
            params: %{value: select(result("added"), [:value]), amount: 2}
          )
        end
      end
    )

    module
  end

  defp registry do
    FlowFixtures.storage_registry()
  end
end
