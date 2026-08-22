defmodule Jido.Flow.BuilderTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Flow
  alias Jido.Flow.{Builder, Constructor}
  alias Jido.Flow.Ref

  alias JidoTest.TestActions.{Add, EchoParamsAction, Multiply}

  test "builds named nodes with named result references" do
    builder =
      Builder.new(name: "builder_math")
      |> Builder.step("added", Add, %{value: Builder.input(:value), amount: 1})
      |> Builder.step("doubled", Multiply, %{
        value: Builder.result("added", :value),
        amount: 2
      })
      |> Builder.return(Builder.result("doubled"))

    assert {:ok, flow} = Builder.build(builder)
    assert [%{name: "added"}, %{name: "doubled"}] = flow.nodes
    assert flow.return == Ref.result("doubled")
    assert {:ok, %{value: 8}} = Jido.Exec.run(flow, %{value: 3}, %{})
  end

  test "uses the canonical Flow constructor and validation path" do
    builder =
      Builder.new(name: "builder_parity", description: "Shared construction")
      |> Builder.step("echo", EchoParamsAction, %{value: Builder.input(:value)},
        after: [],
        meta: %{source: :builder}
      )

    assert {:ok, built} = Builder.build(builder)

    assert {:ok, direct} =
             Flow.new(%{
               name: "builder_parity",
               description: "Shared construction",
               nodes: [
                 %{
                   name: "echo",
                   action: EchoParamsAction,
                   input: %{value: Ref.input(:value)},
                   deps: [],
                   provenance: %{source: :builder}
                 }
               ],
               return: Ref.result("echo")
             })

    assert Flow.to_map(built, provenance: true) == Flow.to_map(direct, provenance: true)
  end

  test "supports canonical collection, choice, and Iterator values" do
    condition = Builder.eq(Builder.input(:route), Builder.value(:add))

    builder =
      Builder.new(name: "closed_builder")
      |> Builder.choice(
        "route",
        [Builder.option("add", condition, Add, %{value: 1, amount: 1})],
        Builder.fallback(Multiply, %{value: 1, amount: 2})
      )
      |> Builder.map(
        "mapped",
        Builder.input(:items),
        Multiply,
        %{value: Builder.item(), amount: Builder.result("route", :value)}
      )
      |> Builder.reduce(
        "total",
        Builder.result("mapped"),
        %{value: 0},
        Add,
        %{value: Builder.accumulator(:value), amount: Builder.item(:value)}
      )
      |> Builder.iterate(
        "counted",
        Add,
        %{value: Builder.state(:value), amount: 1},
        %{
          schema: [],
          initial: %{value: Builder.result("total", :value)},
          update: %{value: Builder.body_result(:value)}
        },
        repeat: 2
      )

    assert {:ok, flow} = Builder.build(builder)
    assert Enum.map(flow.nodes, & &1.name) == ["route", "mapped", "total", "counted"]
    assert flow.return == Ref.result("counted")
  end

  test "requires explicit node names" do
    builder =
      Builder.new(name: "missing_name")
      |> Builder.step(nil, Add, %{value: 1})

    assert {:error, error} = Builder.build(builder)
    assert Exception.message(error) =~ "name"
  end

  test "canonical construction returns errors for improper runtime lists" do
    step = %{kind: :step, name: "echo", action: EchoParamsAction, input: %{}}

    assert {:error, %Jido.Action.Error.InvalidInputError{}} =
             Constructor.build(%{
               name: "bad_specs",
               node_specs: [step | :tail],
               return: Ref.result("echo")
             })

    assert {:error, %Jido.Action.Error.InvalidInputError{}} =
             Constructor.build(%{
               name: "bad_after",
               node_specs: [Map.put(step, :after, ["first" | :tail])],
               return: Ref.result("echo")
             })
  end

  test "rejects options that replace positional Step fields" do
    builder =
      Builder.new(name: "protected_step")
      |> Builder.step("original", Add, %{value: 1},
        kind: :map,
        name: "changed",
        action: Multiply,
        input: %{value: 9},
        collection: Builder.value([1])
      )

    assert {:error, error} = Builder.build(builder)
    assert Exception.message(error) == "Builder step received unsupported options"

    assert error.details.options == [:action, :collection, :input, :kind, :name]
    assert error.details.path == [:nodes, 0, :options]
  end

  test "does not expose assignment-era forms" do
    refute function_exported?(Builder, :binding, 1)
    refute function_exported?(Builder, :bind, 2)
    refute function_exported?(Builder, :branch, 2)
    refute function_exported?(Builder, :branch, 3)
    refute function_exported?(Builder, :group, 2)
    refute function_exported?(Builder, :group, 3)
  end

  test "select appends a path to a canonical reference" do
    assert Builder.select(Builder.result("load", :payload), [:items, 0]) ==
             Ref.result("load", [:payload, :items, 0])
  end
end
