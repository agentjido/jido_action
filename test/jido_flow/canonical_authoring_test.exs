defmodule Jido.Flow.CanonicalAuthoringTest.SparkFlow do
  @moduledoc false
  use Jido.Flow, name: "canonical_spark_flow"

  flow do
    step("add",
      action: JidoActionTest.Fixtures.Actions.Add,
      params: %{value: input(:value), amount: value(1)},
      needs: [],
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
      action: JidoActionTest.Fixtures.NestedFlow,
      params: %{value: input(:value)},
      meta: %{owner: "spark"}
    )

    output(result("child"))
  end
end

defmodule Jido.Flow.CanonicalAuthoringTest.SparkDispatchFlow do
  @moduledoc false
  use Jido.Flow, name: "canonical_dispatch_flow"

  flow do
    dispatch("next",
      decision: JidoActionTest.Fixtures.Actions.Add,
      expander: JidoActionTest.Fixtures.Actions.Add,
      params: %{value: input(:value), amount: 1},
      meta: %{owner: "spark"}
    )

    output(result("next"))
  end
end

defmodule Jido.Flow.CanonicalAuthoringTest.SparkMixedFlow do
  @moduledoc false
  use Jido.Flow, name: "canonical_mixed_flow", description: "All canonical authoring forms"
  alias JidoActionTest.Fixtures.Actions.Multiply

  flow do
    step("load",
      action: JidoActionTest.Fixtures.Actions.Add,
      params: %{value: input(:value), amount: 1},
      meta: %{owner: "parity"}
    )

    step("child",
      action: JidoActionTest.Fixtures.NestedFlow,
      params: %{value: result("load", :value)},
      needs: ["load"]
    )

    choice("route") do
      option("add",
        condition: input(:kind) == :add,
        action: JidoActionTest.Fixtures.Actions.Add,
        params: %{value: result("child", :value), amount: 1}
      )

      otherwise(action: Multiply, params: %{value: result("child", :value), amount: 2})
    end

    map("mapped",
      collection: input(:items),
      action: JidoActionTest.Fixtures.Actions.Add,
      params: %{value: item(:value), amount: 1},
      on_error: :collect_errors
    )

    reduce("reduced",
      collection: result("mapped"),
      initial: %{value: 1},
      action: JidoActionTest.Fixtures.Actions.Multiply,
      params: %{value: accumulator(:value), amount: item(:value)}
    )

    iterate("loop") do
      state([], initial: %{count: 0})
      action(JidoActionTest.Fixtures.Actions.Add)
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
  alias Jido.Flow.Choice
  alias Jido.Flow.Codec
  alias Jido.Flow.Dispatch
  alias Jido.Flow.Iterate
  alias Jido.Flow.Map, as: FlowMap
  alias Jido.Flow.Reduce
  alias Jido.Flow.Ref
  alias Jido.Flow.Step
  alias Jido.Flow.Subflow
  alias JidoActionTest.Fixtures.CodecRegistry
  alias JidoActionTest.Fixtures.FlowAuthoring
  alias JidoActionTest.Fixtures.InlineAuthoring
  alias JidoActionTest.Fixtures.InlineParityFlow
  alias JidoActionTest.Fixtures.NestedFlow
  alias JidoActionTest.Fixtures.Actions.Add

  test "all inline binding forms have equal DSL, direct, and JSON graphs and results" do
    direct = InlineAuthoring.direct_flow!()
    assert {:ok, built} = Jido.Flow.new(InlineAuthoring.data())
    dsl = InlineParityFlow.flow()
    assert built == direct
    assert dsl == direct
    registry = InlineAuthoring.registry()
    assert {:ok, document} = Codec.encode(built, registry)

    assert Enum.map(document["components"], & &1["action"]) == [
             "actions/demo/empty/v1",
             "actions/demo/named/v1",
             "actions/demo/multiple/v1",
             "actions/demo/sole-map/v1"
           ]

    assert {:ok, decoded} =
             document |> Jason.encode!() |> Jason.decode!() |> Codec.decode(registry)

    assert decoded == direct

    input = %{
      raw_name: " Ada ",
      payload: %{"profile" => %{"city" => "London"}, "active" => true, "extra" => "preserved"}
    }

    expected = %{
      "empty" => %{ready: true},
      "greeting" => %{message: "Welcome, Ada!"},
      "profile" => %{city: "London"}
    }

    for flow <- [dsl, built, direct, decoded] do
      assert Jido.Exec.run(flow, input, %{prefix: "Welcome"}) == {:ok, expected}
    end
  end

  test "looked-up Actions use only the new map authoring refs, dependencies, and metadata" do
    action = InlineParityFlow.step_action(:multiple)

    assert {:ok, flow} =
             Jido.Flow.new(%{
               output: Jido.Flow.Ref.result("message"),
               components: [
                 %{
                   kind: :step,
                   name: "gate",
                   action: InlineParityFlow.step_action(:empty),
                   params: %{}
                 },
                 %{
                   kind: :step,
                   name: "message",
                   action: action,
                   params: %{
                     name: Jido.Flow.Ref.input(:recipient),
                     prefix: Jido.Flow.Ref.input(:salutation)
                   },
                   needs: ["gate"],
                   meta: %{owner: "data"}
                 }
               ],
               name: "reused_inline"
             })

    assert [_, %Step{} = reused] = flow.components
    assert reused.action == action
    assert reused.params == %{name: Ref.input(:recipient), prefix: Ref.input(:salutation)}
    assert reused.needs == ["gate"]
    assert reused.meta == %{owner: "data"}

    assert {:ok, %{"message" => %{needs: ["gate"], references: [], effective: ["gate"]}}} =
             Flow.dependencies(flow)

    assert Jido.Exec.run(flow, %{recipient: "Grace", salutation: "Hi"}) ==
             {:ok, %{message: "Hi, Grace!"}}
  end

  test "a normal Map can reuse a looked-up inline Action with item refs" do
    action = InlineParityFlow.step_action("named")

    assert {:ok, flow} =
             Jido.Flow.new(%{
               output: %{names: Jido.Flow.Ref.result("names")},
               components: [
                 %{
                   kind: :map,
                   name: "names",
                   collection: Jido.Flow.Ref.input(:people),
                   action: action,
                   params: %{name: Jido.Flow.Ref.item()}
                 }
               ],
               name: "mapped_inline"
             })

    assert [%FlowMap{action: ^action, params: %{name: %Ref{source: :item}}}] = flow.components

    assert Jido.Exec.run(flow, %{people: [" Ada ", " Grace "]}) ==
             {:ok, %{names: [%{name: "Ada"}, %{name: "Grace"}]}}
  end

  test "direct, and Spark Step authoring produce the same canonical data" do
    direct =
      Flow.new!(
        name: "canonical_spark_flow",
        components: [
          Step.new!(
            name: "add",
            action: Add,
            params: %{value: Ref.input(:value), amount: 1},
            needs: [],
            meta: %{owner: "spark"}
          )
        ],
        output: Ref.result("add")
      )

    {:ok, built} =
      Jido.Flow.new(%{
        output: Jido.Flow.Ref.result("add"),
        components: [
          %{
            kind: :step,
            name: "add",
            action: Add,
            params: %{value: Jido.Flow.Ref.input(:value), amount: 1},
            needs: [],
            meta: %{owner: "spark"}
          }
        ],
        name: "canonical_spark_flow"
      })

    assert built == direct
    assert Jido.Flow.CanonicalAuthoringTest.SparkFlow.flow() == direct
  end

  test "Spark derives a Subflow and map authoring declares its kind" do
    direct =
      Flow.new!(
        name: "canonical_spark_subflow",
        components: [
          Subflow.new!(
            name: "child",
            flow: NestedFlow,
            params: %{value: Ref.input(:value)},
            needs: [],
            meta: %{owner: "spark"}
          )
        ],
        output: Ref.result("child")
      )

    {:ok, built} =
      Jido.Flow.new(%{
        output: Jido.Flow.Ref.result("child"),
        components: [
          %{
            kind: :subflow,
            flow: NestedFlow,
            name: "child",
            params: %{value: Jido.Flow.Ref.input(:value)},
            meta: %{owner: "spark"}
          }
        ],
        name: "canonical_spark_subflow"
      })

    assert built == direct
    assert Jido.Flow.CanonicalAuthoringTest.SparkSubflow.flow() == direct
    assert [%Subflow{}] = built.components
  end

  test "direct, Spark, and JSON Dispatch forms produce the same canonical data" do
    direct =
      Flow.new!(
        name: "canonical_dispatch_flow",
        components: [
          Dispatch.new!(
            name: "next",
            decision: Add,
            expander: Add,
            params: %{value: Ref.input(:value), amount: 1},
            meta: %{owner: "spark"}
          )
        ],
        output: Ref.result("next")
      )

    {:ok, built} =
      Jido.Flow.new(%{
        output: Jido.Flow.Ref.result("next"),
        components: [
          %{
            kind: :dispatch,
            name: "next",
            decision: Add,
            expander: Add,
            params: %{value: Jido.Flow.Ref.input(:value), amount: 1},
            meta: %{owner: "spark"}
          }
        ],
        name: "canonical_dispatch_flow"
      })

    assert built == direct
    assert Jido.Flow.CanonicalAuthoringTest.SparkDispatchFlow.flow() == direct
    assert {:ok, document, registry} = Codec.encode(direct)
    assert [%{"kind" => "dispatch"} = encoded] = document["components"]
    refute Map.has_key?(encoded, "max_continuations")
    assert Codec.decode(document, registry) == {:ok, direct}
  end

  test "direct, Spark, and JSON authoring produce one mixed canonical Flow" do
    direct = FlowAuthoring.mixed_flow!()
    assert {:ok, built} = Jido.Flow.new(FlowAuthoring.mixed_data())
    assert Jido.Flow.CanonicalAuthoringTest.SparkMixedFlow.flow() == direct
    assert built == direct
    registry = CodecRegistry.mixed()
    assert {:ok, document} = Codec.encode(direct, registry)
    json = Jason.encode!(document)
    assert {:ok, decoded} = json |> Jason.decode!() |> Codec.decode(registry)
    assert decoded == direct

    assert Enum.map(direct.components, & &1.__struct__) == [
             Step,
             Subflow,
             Choice,
             FlowMap,
             Reduce,
             Iterate
           ]

    compiled_forms =
      for flow <- [direct, built, decoded, Jido.Flow.CanonicalAuthoringTest.SparkMixedFlow.flow()] do
        assert {:ok, compiled} = Flow.compile(flow)

        {compiled.workflow.graph, compiled.work_index, compiled.component_index,
         compiled.semantic_digest, compiled.compilation_digest}
      end

    assert length(Enum.uniq(compiled_forms)) == 1
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

  test "map authoring rejects removed aliases" do
    assert {:error, error} =
             Jido.Flow.new(%{
               output: Jido.Flow.Ref.result("add"),
               components: [
                 %{kind: :step, name: "add", action: Add, params: %{}, deps: ["other"]}
               ],
               name: "bad_data"
             })

    assert Exception.message(error) == "unknown step configuration key: :deps"
  end

  test "map authoring accepts needs for every component kind" do
    option = %{name: "yes", condition: true, action: Add, params: %{}}
    fallback = %{action: Add, params: %{}}

    assert {:ok, flow} =
             Jido.Flow.new(%{
               output: Jido.Flow.Ref.result("dispatch"),
               components: [
                 %{kind: :step, name: "root", action: Add, params: %{}},
                 %{kind: :step, name: "action", action: Add, params: %{}, needs: ["root"]},
                 %{
                   kind: :subflow,
                   flow: NestedFlow,
                   name: "subflow",
                   params: %{},
                   needs: ["root"]
                 },
                 %{
                   kind: :choice,
                   name: "choice",
                   options: [option],
                   fallback: fallback,
                   needs: ["root"]
                 },
                 %{
                   kind: :map,
                   name: "map",
                   collection: [],
                   action: Add,
                   params: %{},
                   needs: ["root"]
                 },
                 %{
                   kind: :reduce,
                   name: "reduce",
                   collection: [],
                   initial: %{},
                   action: Add,
                   params: %{},
                   needs: ["root"]
                 },
                 %{
                   kind: :iterate,
                   name: "iterate",
                   action: Add,
                   params: %{},
                   state: [schema: [], initial: %{}, update: %{}],
                   needs: ["root"],
                   completion: true,
                   max_iterations: 1
                 },
                 %{
                   kind: :dispatch,
                   name: "dispatch",
                   decision: Add,
                   expander: Add,
                   params: %{},
                   needs: ["action", "subflow", "choice", "map", "reduce", "iterate"]
                 }
               ],
               name: "all_data_needs"
             })

    assert Enum.map(flow.components, &{&1.__struct__, &1.needs}) == [
             {Step, []},
             {Step, ["root"]},
             {Subflow, ["root"]},
             {Choice, ["root"]},
             {FlowMap, ["root"]},
             {Reduce, ["root"]},
             {Iterate, ["root"]},
             {Dispatch, ["action", "subflow", "choice", "map", "reduce", "iterate"]}
           ]
  end

  test "map authoring rejects after for every component kind" do
    option = %{name: "yes", condition: true, action: Add, params: %{}}
    fallback = %{action: Add, params: %{}}
    state = [schema: [], initial: %{}, update: %{}]

    definitions = [
      %{
        components: [%{kind: :step, name: "step", action: Add, params: %{}, after: []}],
        name: "step_after"
      },
      %{
        components: [%{kind: :subflow, flow: NestedFlow, name: "subflow", params: %{}, after: []}],
        name: "subflow_after"
      },
      %{
        components: [
          %{kind: :choice, name: "choice", options: [option], fallback: fallback, after: []}
        ],
        name: "choice_after"
      },
      %{
        components: [
          %{kind: :map, name: "map", collection: [], action: Add, params: %{}, after: []}
        ],
        name: "map_after"
      },
      %{
        components: [
          %{
            kind: :reduce,
            name: "reduce",
            collection: [],
            initial: %{},
            action: Add,
            params: %{},
            after: []
          }
        ],
        name: "reduce_after"
      },
      %{
        components: [
          %{kind: :iterate, name: "iterate", action: Add, params: %{}, state: state, after: []}
        ],
        name: "iterate_after"
      },
      %{
        components: [
          %{
            kind: :dispatch,
            name: "dispatch",
            decision: Add,
            expander: Add,
            params: %{},
            after: []
          }
        ],
        name: "dispatch_after"
      }
    ]

    for data <- definitions do
      assert {:error, error} = Jido.Flow.new(Map.put(data, :output, %{}))
      assert error.message =~ "unknown"
      assert error.message =~ ":after"
      assert error.details.path == [:components, 0]
    end
  end

  test "map authoring still requires an explicit output" do
    assert {:error, error} =
             Jido.Flow.new(%{
               components: [%{kind: :step, name: "step", action: Add, params: %{}}],
               name: "missing_output"
             })

    assert error.message == "Flow output is required"
    assert error.details.path == [:output]
  end

  test "public inspection exposes needs and sorted effective dependencies" do
    flow =
      Flow.new!(
        name: "dependency_inspection",
        components: [
          Step.new!(name: "beta", action: Add),
          Step.new!(name: "alpha", action: Add),
          Step.new!(
            name: "work",
            action: Add,
            params: [Ref.result("beta"), Ref.result("alpha"), Ref.result("beta")],
            needs: ["beta", "alpha"]
          )
        ],
        output: Ref.result("work")
      )

    assert %{components: [_beta, _alpha, work]} = Flow.to_map(flow)
    assert work.needs == ["beta", "alpha"]
    refute Map.has_key?(work, :after)
    assert {:ok, dependencies} = Flow.dependencies(flow)

    assert dependencies["work"] == %{
             needs: ["beta", "alpha"],
             references: ["alpha", "beta"],
             effective: ["alpha", "beta"]
           }

    assert {:ok, %{version: 1, dependencies: ^dependencies}} = Flow.explain(flow)
  end

  test "canonical public operations accept one Flow and reject other subjects" do
    flow = FlowAuthoring.math_flow!()
    assert Flow.new(flow) == {:ok, flow}
    assert %Jido.Exec.Flow.Compiled{} = Flow.compile!(flow, %{})
    assert %{name: "math_flow", components: [_first, _second]} = Flow.to_map(flow)
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
          Step.new!(name: "missing", action: JidoActionTest.Fixtures.Actions.MissingRun)
        ],
        output: Ref.result("missing")
      )

    assert_raise Jido.Flow.Error.InvalidDefinitionError, fn -> Flow.compile!(invalid) end

    assert_raise Jido.Flow.Error.InvalidDefinitionError, fn ->
      Flow.new!(name: "missing_output")
    end
  end
end
