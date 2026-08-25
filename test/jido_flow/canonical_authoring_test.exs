defmodule Jido.Flow.CanonicalAuthoringTest.SparkFlow do
  @moduledoc false

  use Jido.Flow, name: "canonical_spark_flow"

  flow do
    step("add",
      action: JidoActionTest.TestActions.Add,
      params: %{value: input(:value), amount: value(1)},
      after: [],
      meta: %{owner: "spark"}
    )

    output(result("add"))
  end
end

defmodule Jido.Flow.CanonicalAuthoringTest.SparkSubflow do
  @moduledoc false

  use Jido.Flow, name: "canonical_spark_subflow"

  flow do
    step("child",
      action: JidoActionTest.FlowFixtures.NestedFlow,
      params: %{value: input(:value)},
      meta: %{owner: "spark"}
    )

    output(result("child"))
  end
end

defmodule Jido.Flow.CanonicalAuthoringTest.SparkMixedFlow do
  @moduledoc false

  use Jido.Flow,
    name: "canonical_mixed_flow",
    description: "All canonical authoring forms"

  flow do
    step("load",
      action: JidoActionTest.TestActions.Add,
      params: %{value: input(:value), amount: 1},
      meta: %{owner: "parity"}
    )

    step("child",
      action: JidoActionTest.FlowFixtures.NestedFlow,
      params: %{value: result("load", :value)},
      after: ["load"]
    )

    choice "route" do
      option("add",
        condition: input(:kind) == :add,
        action: JidoActionTest.TestActions.Add,
        params: %{value: result("child", :value), amount: 1}
      )

      otherwise(
        action: JidoActionTest.TestActions.Multiply,
        params: %{value: result("child", :value), amount: 2}
      )
    end

    map("mapped",
      collection: input(:items),
      action: JidoActionTest.TestActions.Add,
      params: %{value: item(:value), amount: 1},
      on_error: :collect_errors
    )

    reduce("reduced",
      collection: result("mapped"),
      initial: %{value: 1},
      action: JidoActionTest.TestActions.Multiply,
      params: %{value: accumulator(:value), amount: item(:value)}
    )

    iterate "loop" do
      state([], initial: %{count: 0})
      action(JidoActionTest.TestActions.Add)
      params(%{value: state(:count), amount: 1})
      update(%{count: body_result(:value)})
      repeat(2)
    end

    output(result("loop"))
  end
end

defmodule Jido.Flow.CanonicalAuthoringTest do
  use ExUnit.Case, async: true

  alias Jido.Flow
  alias Jido.Flow.Builder
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

  test "direct, Builder, and Spark Step authoring produce the same canonical data" do
    direct =
      Flow.new!(
        name: "canonical_spark_flow",
        components: [
          Step.new!(
            name: "add",
            action: Add,
            params: %{value: Ref.input(:value), amount: 1},
            after: [],
            meta: %{owner: "spark"}
          )
        ],
        output: Ref.result("add")
      )

    {:ok, built} =
      Builder.new(name: "canonical_spark_flow")
      |> Builder.step(
        "add",
        Add,
        %{value: Builder.input(:value), amount: Builder.value(1)},
        after: [],
        meta: %{owner: "spark"}
      )
      |> Builder.output(Builder.result("add"))
      |> Builder.build()

    assert built == direct
    assert Jido.Flow.CanonicalAuthoringTest.SparkFlow.flow() == direct
  end

  test "only step derives a Subflow through Spark and Builder" do
    direct =
      Flow.new!(
        name: "canonical_spark_subflow",
        components: [
          Subflow.new!(
            name: "child",
            flow: NestedFlow,
            params: %{value: Ref.input(:value)},
            after: [],
            meta: %{owner: "spark"}
          )
        ],
        output: Ref.result("child")
      )

    {:ok, built} =
      Builder.new(name: "canonical_spark_subflow")
      |> Builder.step(
        "child",
        NestedFlow,
        %{value: Builder.input(:value)},
        meta: %{owner: "spark"}
      )
      |> Builder.output(Builder.result("child"))
      |> Builder.build()

    assert built == direct
    assert Jido.Flow.CanonicalAuthoringTest.SparkSubflow.flow() == direct
    assert [%Subflow{}] = built.components
  end

  test "direct, Builder, Spark, and JSON authoring produce one mixed canonical Flow" do
    direct = direct_mixed_flow()

    assert {:ok, built} = built_mixed_flow()
    assert Jido.Flow.CanonicalAuthoringTest.SparkMixedFlow.flow() == direct
    assert built == direct

    registry = mixed_registry()
    assert {:ok, document} = Codec.encode(direct, registry)
    json = Jason.encode!(document)
    assert {:ok, decoded} = json |> Jason.decode!() |> Codec.decode(registry)
    assert decoded == direct

    assert Enum.map(direct.components, & &1.__struct__) ==
             [Step, Subflow, Choice, FlowMap, Reduce, Iterate]
  end

  test "Spark source data stays outside the canonical Flow" do
    flow = Jido.Flow.CanonicalAuthoringTest.SparkFlow.flow()
    source_map = Jido.Flow.CanonicalAuthoringTest.SparkFlow.__jido_flow_source_map__()

    assert flow.components |> hd() |> Map.fetch!(:meta) == %{owner: "spark"}
    refute Map.has_key?(flow.components |> hd() |> Map.fetch!(:meta), :line)
    assert %{file: file, line: line} = source_map[[:components, "add"]]
    assert is_binary(file)
    assert is_integer(line)
    assert %{file: ^file} = source_map[[:output]]
  end

  test "Builder rejects removed aliases" do
    assert {:error, error} =
             Builder.new(name: "bad_builder")
             |> Builder.step("add", Add, %{}, deps: ["other"])
             |> Builder.output(Builder.result("add"))
             |> Builder.build()

    assert Exception.message(error) =~ "unsupported fields"
    refute function_exported?(Builder, :return, 2)
  end

  test "canonical public operations accept one Flow and reject other subjects" do
    flow = JidoActionTest.FlowFixtures.math_flow!()

    assert Flow.new(flow) == {:ok, flow}
    assert %Jido.Flow.Compiled{} = Flow.compile!(flow, %{})
    assert %{name: "math_flow", components: [_first, _second]} = Flow.to_map(flow)
    assert length(Flow.canonical_components(flow.components)) == 2
    assert {:ok, %{"double" => %{references: ["add_one"]}}} = Flow.dependencies(flow)
    assert {:ok, %{kind: :flow, name: "math_flow"}} = Flow.explain(flow)
    assert {:ok, %{digest: digest, uuid: uuid}} = Flow.semantic_identity(flow)
    assert is_binary(digest)
    assert is_binary(uuid)
    assert {:ok, ^flow} = Flow.validate(flow)
    assert {:ok, ^flow} = Flow.validate_executable(flow)

    for operation <- [
          &Flow.dependencies/1,
          &Flow.explain/1,
          &Flow.semantic_identity/1,
          &Flow.validate/1,
          &Flow.validate_executable/1
        ] do
      assert {:error, error} = operation.(:not_a_flow)
      assert Exception.message(error) == "expected a Jido.Flow artifact"
    end

    invalid =
      Flow.new!(
        name: "compile_bang_error",
        components: [
          Step.new!(name: "missing", action: JidoActionTest.TestActions.MissingRun)
        ],
        output: Ref.result("missing")
      )

    assert_raise Jido.Action.Error.InvalidInputError, fn -> Flow.compile!(invalid) end
    assert_raise Jido.Action.Error.InvalidInputError, fn -> Flow.new!(name: "missing_output") end
  end

  defp direct_mixed_flow do
    Flow.new!(
      name: "canonical_mixed_flow",
      description: "All canonical authoring forms",
      components: [
        Step.new!(
          name: "load",
          action: Add,
          params: %{value: Ref.input(:value), amount: 1},
          meta: %{owner: "parity"}
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
              condition: Condition.eq(Ref.input(:kind), :add),
              action: Add,
              params: %{value: Ref.result("child", :value), amount: 1}
            )
          ],
          fallback:
            Choice.Fallback.new!(
              action: Multiply,
              params: %{value: Ref.result("child", :value), amount: 2}
            )
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
          state:
            Iterate.State.new!(
              schema: [],
              initial: %{count: 0},
              update: %{count: Ref.body_result(:value)}
            ),
          completion: Condition.gte(Ref.iteration_index(), 2),
          max_iterations: 2
        )
      ],
      output: Ref.result("loop")
    )
  end

  defp built_mixed_flow do
    Builder.new(
      name: "canonical_mixed_flow",
      description: "All canonical authoring forms"
    )
    |> Builder.step(
      "load",
      Add,
      %{value: Builder.input(:value), amount: 1},
      meta: %{owner: "parity"}
    )
    |> Builder.step(
      "child",
      NestedFlow,
      %{value: Builder.result("load", :value)},
      after: ["load"]
    )
    |> Builder.choice(
      "route",
      [
        Builder.option(
          "add",
          Builder.eq(Builder.input(:kind), :add),
          Add,
          %{value: Builder.result("child", :value), amount: 1}
        )
      ],
      Builder.fallback(
        Multiply,
        %{value: Builder.result("child", :value), amount: 2}
      )
    )
    |> Builder.map(
      "mapped",
      Builder.input(:items),
      Add,
      %{value: Builder.item(:value), amount: 1},
      on_error: :collect_errors
    )
    |> Builder.reduce(
      "reduced",
      Builder.result("mapped"),
      %{value: 1},
      Multiply,
      %{value: Builder.accumulator(:value), amount: Builder.item(:value)}
    )
    |> Builder.iterate(
      "loop",
      Add,
      %{value: Builder.state(:count), amount: 1},
      %{
        schema: [],
        initial: %{count: 0},
        update: %{count: Builder.body_result(:value)}
      },
      completion: Builder.gte(Builder.iteration_index(), 2),
      max_iterations: 2
    )
    |> Builder.output(Builder.result("loop"))
    |> Builder.build()
  end

  defp mixed_registry do
    Registry.new!(%{
      "actions/add" => {:action, Add},
      "actions/multiply" => {:action, Multiply},
      "flows/nested" => {:flow, NestedFlow},
      "schemas/empty" => {:schema, []},
      "atoms/add" => {:atom, :add},
      "atoms/amount" => {:atom, :amount},
      "atoms/count" => {:atom, :count},
      "atoms/items" => {:atom, :items},
      "atoms/kind" => {:atom, :kind},
      "atoms/owner" => {:atom, :owner},
      "atoms/value" => {:atom, :value}
    })
  end
end
