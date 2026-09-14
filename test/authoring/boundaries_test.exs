Code.require_file("support/components.ex", __DIR__)
Code.require_file("support/boundaries.ex", __DIR__)

defmodule JidoActionTest.Authoring.BoundariesTest do
  use ExUnit.Case, async: false
  @moduletag :authoring

  alias Jido.{Exec, Expr, Flow}
  alias Jido.Flow.{Builder, Codec, Ref, Registry, Step}
  alias JidoActionTest.Authoring.Boundaries
  alias JidoActionTest.Authoring.Components.Echo

  test "complete inline binding forms run and an extracted target keeps only its Action" do
    assert Exec.run(Boundaries.Inline, %{value: 2, right: 3}, %{label: "ctx"}) ==
             {:ok, %{none: %{value: 1}, final: %{value: 12, label: "ctx"}}}

    action = Boundaries.Inline.step_action("ctx")
    output = Ref.result("reused")

    direct =
      Flow.new!(
        name: "reused_inline",
        components: [
          Step.new!(name: "reused", action: action, params: %{value: Ref.input(:value)})
        ],
        output: output
      )

    builder =
      Builder.new(name: "reused_inline")
      |> Builder.step("reused", action, %{value: Builder.input(:value)})
      |> Builder.output(output)

    assert {:ok, built} = Builder.build(builder)
    assert built == direct

    for flow <- [direct, built] do
      assert Exec.run(flow, %{value: 8}, %{label: "reused"}) ==
               {:ok, %{value: 8, label: "reused"}}
    end

    registry =
      Registry.new!(%{
        "actions/inline-ctx/v1" => {:action, action},
        "schemas/none/v1" => {:schema, []},
        "atoms/value" => {:atom, :value}
      })

    assert {:ok, document} = Codec.encode(direct, registry)
    assert {:ok, ^direct} = Codec.decode(JSON.decode!(JSON.encode!(document)), registry)
    assert get_in(document, ["components", Access.at(0), "action"]) == "actions/inline-ctx/v1"
    assert_raise ArgumentError, fn -> Boundaries.Inline.step_action("missing") end
  end

  test "nested operations agree across source, direct, Builder, and version 2 JSON" do
    output = %{
      total: Expr.new!(:add, [Expr.new!(:multiply, [Ref.input(:a), Ref.input(:b)]), 1]),
      flags: [
        Expr.new!(:all, [Ref.input(:enabled), Expr.new!(:not, [Ref.context(:paused)])]),
        Expr.new!(:eq, [Ref.input(:maybe), nil])
      ],
      message: Expr.new!(:concat, ["Hi ", Ref.result("echo", :name)])
    }

    direct =
      Flow.new!(
        name: Boundaries.Expressions.name(),
        components: [Step.new!(name: "echo", action: Echo, params: %{name: Ref.input(:name)})],
        output: output
      )

    builder =
      Builder.new(name: Boundaries.Expressions.name())
      |> Builder.step("echo", Echo, %{name: Builder.input(:name)})
      |> Builder.output(output)

    assert Boundaries.Expressions.flow() == direct
    assert {:ok, built} = Builder.build(builder)
    assert built == direct
    assert {:ok, document, registry} = Codec.encode(direct)
    assert document["version"] == 2
    assert {:ok, restored} = Codec.decode(JSON.decode!(JSON.encode!(document)), registry)
    assert restored == direct

    input = %{name: "Ada", a: 2, b: 3, enabled: true, maybe: nil}
    expected = %{total: 7, flags: [true, true], message: "Hi Ada"}

    for form <- [Boundaries.Expressions, direct, built, restored] do
      assert Exec.run(form, input, %{paused: false}) == {:ok, expected}
    end
  end

  test "Flow and Action schemas fail at their own boundaries, and Flow discards extras" do
    assert Exec.run(Boundaries.SchemaFlow, %{}) == {:ok, %{value: 2}}
    assert Exec.run(Boundaries.SchemaFlow, %{value: 3}) == {:ok, %{value: 4}}

    assert {:error, input_error} = Exec.run(Boundaries.SchemaFlow, %{value: "bad"})
    assert input_error.details.node_path == ["work"]

    assert {:error, output_error} =
             Exec.run(Boundaries.SchemaFlow, %{value: 3}, %{mode: :bad_output})

    assert output_error.details.node_path == ["work"]
    assert {:error, root_error} = Exec.run(Boundaries.BadRootOutput, %{value: 3})
    assert root_error != output_error
  end

  test "inspection and all four canonical forms never execute Action work" do
    direct =
      Flow.new!(
        name: Boundaries.Inert.name(),
        components: [
          Step.new!(name: "bomb", action: Boundaries.Bomb, params: %{value: Ref.input(:value)})
        ],
        output: %{value: Ref.result("bomb", :value)}
      )

    builder =
      Builder.new(name: Boundaries.Inert.name())
      |> Builder.step("bomb", Boundaries.Bomb, %{value: Builder.input(:value)})
      |> Builder.output(%{value: Builder.result("bomb", :value)})

    assert {:ok, built} = Builder.build(builder)
    assert {:ok, document, registry} = Codec.encode(direct)
    assert {:ok, restored} = Codec.decode(JSON.decode!(JSON.encode!(document)), registry)
    assert Boundaries.Inert.flow() == direct
    assert built == direct
    assert restored == direct
    assert {:ok, dependencies} = Flow.dependencies(direct)
    assert {:ok, explanation} = Flow.explain(direct)
    assert {:ok, identity} = Flow.semantic_identity(direct)

    for flow <- [Boundaries.Inert.flow(), direct, built, restored] do
      assert {:ok, ^flow} = Flow.validate(flow)
      assert {:ok, ^flow} = Flow.validate_executable(flow)
      assert {:ok, ^dependencies} = Flow.dependencies(flow)
      assert {:ok, ^explanation} = Flow.explain(flow)
      assert {:ok, ^identity} = Flow.semantic_identity(flow)
      assert is_binary(identity.digest)
      assert Flow.to_map(flow) == Flow.to_map(direct)
    end

    source_map = Boundaries.Inert.__jido_flow_source_map__()
    assert Map.has_key?(source_map, [:components, "bomb"])
    refute inspect(Flow.to_map(direct)) =~ "test/authoring/support/boundaries.ex"
  end

  test "reference paths distinguish missing, nil, false, and atom or string keys" do
    assert Exec.run(Boundaries.Stored, %{value: nil}) == {:ok, %{value: nil}}

    assert Exec.run(Boundaries.Stored, %{"value" => 7, value: false}) ==
             {:ok, %{value: false}}

    assert Exec.run(Boundaries.Stored, %{"value" => 7}) == {:ok, %{value: 7}}
    assert {:error, %{details: %{reason: :missing_key}}} = Exec.run(Boundaries.Stored, %{})

    assert Exec.run(Boundaries.Paths, %{payload: %{"items" => [nil]}}) ==
             {:ok, %{value: nil}}

    assert {:error, %{details: %{reason: :missing_index, path: [:payload, "items", 0]}}} =
             Exec.run(Boundaries.Paths, %{payload: %{"items" => []}})
  end

  test "raw output is intentional but a normal scalar Flow result is rejected" do
    assert Exec.run(Boundaries.RawFlow) == {:ok, Jido.Action.Output.raw("done")}

    assert {:error, %Jido.Flow.Error.ExecutionFailureError{}} =
             Exec.run(Boundaries.ScalarFlow, %{value: 7})
  end

  test "full, step-wise, and async runs return one authored result" do
    expected = {:ok, %{value: 7}}
    assert Exec.run(Boundaries.Stored, %{value: 7}) == expected

    assert {:ok, execution} = Exec.start(Boundaries.Stored, %{value: 7})
    assert {:ok, execution} = Exec.continue(execution)
    assert Exec.result(execution) == expected

    handle = Exec.run_async(Boundaries.Stored, %{value: 7})
    assert Exec.await(handle, 5_000) == expected
  end

  test "fixed host Registry IDs match the saved JSON document" do
    registry =
      Registry.new!(%{
        "actions/echo/v1" => {:action, Echo},
        "schemas/none/v1" => {:schema, []},
        "atoms/value" => {:atom, :value}
      })

    flow = Boundaries.Stored.flow()
    fixture = Path.join(__DIR__, "support/saved_flow.json")
    json = fixture |> File.read!() |> String.trim()
    document = JSON.decode!(json)

    assert {:ok, ^document} = Codec.encode(flow, registry)
    assert {:ok, restored} = Codec.decode(document, registry)
    assert restored == flow
    assert Exec.run(restored, %{value: 7}) == {:ok, %{value: 7}}
    assert {:ok, ^document} = Codec.encode(restored, registry)
    assert JSON.encode!(document) == json
  end

  test "stored aliases read old IDs but re-encode with the canonical ID" do
    registry =
      Registry.new!(%{
        "actions/echo/v1" => {:action, Echo},
        "actions/echo/old" => {:alias, "actions/echo/v1"},
        "schemas/none/v1" => {:schema, []},
        "atoms/value" => {:atom, :value}
      })

    document =
      __DIR__
      |> Path.join("support/saved_flow.json")
      |> File.read!()
      |> JSON.decode!()

    old = put_in(document, ["components", Access.at(0), "action"], "actions/echo/old")
    assert {:ok, restored} = Codec.decode(old, registry)
    assert {:ok, ^document} = Codec.encode(restored, registry)

    wrong_kind = put_in(document, ["components", Access.at(0), "action"], "schemas/none/v1")

    assert {:error, %Jido.Flow.Error.InvalidDefinitionError{}} =
             Codec.decode(wrong_kind, registry)

    unknown = put_in(document, ["components", Access.at(0), "action"], "actions/absent")

    assert {:error, %{message: "unknown flow registry identifier"}} =
             Codec.decode(unknown, registry)
  end

  test "stored document mutations report source paths without executing work" do
    registry =
      Registry.new!(%{
        "actions/echo/v1" => {:action, Boundaries.Bomb},
        "schemas/none/v1" => {:schema, []},
        "atoms/value" => {:atom, :value}
      })

    document =
      __DIR__
      |> Path.join("support/saved_flow.json")
      |> File.read!()
      |> JSON.decode!()

    [step] = document["components"]

    cases = [
      {Map.put(document, "unexpected", true), ["unexpected"]},
      {put_in(
         document,
         ["output", "entries", Access.at(0), "value", "$ref", "component"],
         "absent"
       ), ["output"]},
      {put_in(document, ["components"], [step, step]), ["components", 1, "name"]},
      {put_in(document, ["components", Access.at(0), "needs"], ["echo"]), ["components"]}
    ]

    for {changed, expected_path} <- cases do
      assert {:error, %Jido.Flow.Error.Invalid{errors: errors}} =
               Codec.diagnose(changed, registry)

      assert Enum.any?(errors, fn error -> error.details.path == expected_path end)
    end
  end

  test "a stored Flow rejects an invalid UTF-8 name before creating an artifact" do
    registry =
      Registry.new!(%{
        "actions/echo/v1" => {:action, Boundaries.Bomb},
        "schemas/none/v1" => {:schema, []},
        "atoms/value" => {:atom, :value}
      })

    document =
      __DIR__
      |> Path.join("support/saved_flow.json")
      |> File.read!()
      |> JSON.decode!()

    assert {:error, _error} = Codec.decode(Map.put(document, "name", <<255>>), registry)
  end

  test "stored documents stop at depth, width, and total-node limits" do
    registry =
      Registry.new!(%{
        "actions/echo/v1" => {:action, Boundaries.Bomb},
        "schemas/none/v1" => {:schema, []},
        "atoms/value" => {:atom, :value}
      })

    document =
      __DIR__
      |> Path.join("support/saved_flow.json")
      |> File.read!()
      |> JSON.decode!()

    too_deep = Enum.reduce(1..101, 0, fn _, nested -> [nested] end)
    too_many = for _ <- 1..1_001, do: List.duplicate(0, 100)

    cases = [
      {Map.put(document, "output", too_deep), "nesting limit"},
      {Map.put(document, "output", List.duplicate(0, 10_001)), "size limit"},
      {Map.put(document, "output", too_many), "total node limit"}
    ]

    for {changed, message} <- cases do
      assert {:error, error} = Codec.decode(changed, registry)
      assert error.message =~ message
    end
  end
end
