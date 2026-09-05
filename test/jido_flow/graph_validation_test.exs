defmodule Jido.Flow.GraphValidationTest do
  use ExUnit.Case, async: true

  alias Jido.Expr
  alias Jido.Flow

  alias Jido.Flow.{
    Builder,
    Choice,
    Codec,
    Condition,
    Dispatch,
    Error,
    Iterate,
    Ref,
    Registry,
    Step,
    Subflow
  }

  alias Jido.Flow.Map, as: FlowMap
  alias Jido.Flow.Reduce
  alias JidoActionTest.Fixtures.NestedFlow

  defmodule ProbeAction do
    use Jido.Action, name: "graph_probe"
    @impl true
    def run(_params, _context), do: raise("validation must not run Action work")
  end

  defp registry do
    Registry.new!(%{
      "action" => {:action, ProbeAction},
      "schema" => {:schema, []},
      "flow" => {:flow, NestedFlow}
    })
  end

  defp stored(components, output) do
    %{
      "type" => "jido.flow",
      "version" => 1,
      "name" => "graph",
      "description" => nil,
      "schema" => "schema",
      "output_schema" => "schema",
      "components" => components,
      "output" => output
    }
  end

  defp stored_step(name, after_names) do
    %{
      "kind" => "step",
      "name" => name,
      "action" => "action",
      "after" => after_names,
      "params" => %{"$type" => "map", "entries" => []},
      "meta" => %{"$type" => "map", "entries" => []}
    }
  end

  defp stored_ref(name),
    do: %{"$ref" => %{"source" => "result", "component" => name, "path" => []}}

  defp step(name, after_names), do: Step.new!(name: name, action: ProbeAction, after: after_names)

  test "direct, Builder, DSL, and stored graphs agree on valid and invalid dependencies" do
    cases = [
      {[{"one", []}, {"two", ["one"]}], "two", :ok},
      {[{"two", ["one"]}, {"one", []}], "two", :ok},
      {[{"one", []}, {"two", []}], "two", :ok},
      {[{"one", ["missing"]}], "one", :error},
      {[{"one", []}], "missing", :error},
      {[{"one", ["one"]}], "one", :error},
      {[{"one", ["two"]}, {"two", ["one"]}], "one", :error},
      {[{"one", []}, {"one", []}], "one", :error}
    ]

    for {{edges, output, expected}, index} <- Enum.with_index(cases) do
      components = Enum.map(edges, fn {name, after_names} -> step(name, after_names) end)
      direct = Flow.new(name: "graph", components: components, output: Ref.result(output))

      built =
        Enum.reduce(edges, Builder.new(name: "graph"), fn {name, after_names}, builder ->
          Builder.step(builder, name, ProbeAction, %{}, after: after_names)
        end)
        |> Builder.output(Ref.result(output))
        |> Builder.build()

      document =
        stored(
          Enum.map(edges, fn {name, after_names} -> stored_step(name, after_names) end),
          stored_ref(output)
        )

      decoded = Codec.decode(document, registry())
      module = Module.concat(__MODULE__, "DependencyCase#{index}")

      declarations =
        Enum.map_join(edges, "\n", fn {name, after_names} ->
          "step #{inspect(name)}, action: #{inspect(ProbeAction)}, params: %{}, after: #{inspect(after_names)}"
        end)

      source = """
      defmodule #{inspect(module)} do
        use Jido.Flow, name: "graph"
        flow do
          #{declarations}
          output(result(#{inspect(output)}))
        end
      end
      """

      case expected do
        :ok ->
          assert {:ok, flow} = direct
          assert {:ok, ^flow} = built
          assert {:ok, ^flow} = decoded
          Code.compile_string(source)
          assert module.flow() == flow
          assert {:ok, ^flow} = Flow.validate(flow)

        :error ->
          assert {:error, %Error.InvalidDefinitionError{}} = direct
          assert {:error, %Error.InvalidDefinitionError{}} = built
          assert {:error, %Error.InvalidDefinitionError{}} = decoded
          assert_raise CompileError, fn -> Code.compile_string(source) end
      end
    end
  end

  test "canonical first errors and Codec aggregates retain their different dependency order" do
    component = step("one", ["z_missing", "a_missing"])

    assert {:error, error} =
             Flow.new(name: "graph", components: [component], output: Ref.result("one"))

    assert error.details == %{owner: "one", component: "z_missing"}

    document = stored([stored_step("one", component.after)], stored_ref("one"))
    assert {:error, %Error.Invalid{errors: errors}} = Codec.diagnose(document, registry())

    assert Enum.map(errors, & &1.details) == [
             %{owner: "one", component: "a_missing", path: ["components", 0]},
             %{owner: "one", component: "z_missing", path: ["components", 0]}
           ]

    assert {:error, first} = Codec.decode(document, registry())
    assert first.details == hd(errors).details
  end

  test "duplicates and missing references aggregate without cycle or Dispatch cascades" do
    components = [stored_step("same", ["z_missing", "a_missing"]), stored_step("same", ["same"])]
    output = [stored_ref("out_z"), stored_ref("out_a"), stored_ref("out_z")]

    assert {:error, %Error.Invalid{errors: errors}} =
             Codec.diagnose(stored(components, output), registry())

    assert Enum.map(errors, & &1.details) == [
             %{name: "same", path: ["components", 1, "name"]},
             %{owner: :output, component: "out_z", path: ["output"]},
             %{owner: :output, component: "out_a", path: ["output"]},
             %{owner: "same", component: "a_missing", path: ["components", 0]},
             %{owner: "same", component: "z_missing", path: ["components", 0]}
           ]

    assert {:error, error} =
             Flow.new(
               name: "graph",
               components: [step("same", ["missing"]), step("same", [])],
               output: Ref.result("missing_output")
             )

    assert error.details == %{name: "same"}
  end

  test "nil output retains canonical and stored graph error precedence" do
    components = [step("same", []), step("same", [])]

    assert {:error, %{message: "Flow output is required", details: %{path: [:output]}}} =
             Flow.new(name: "graph", components: components, output: nil)

    assert {:error, %Error.Invalid{errors: [duplicate]}} =
             Codec.diagnose(
               stored([stored_step("same", []), stored_step("same", [])], nil),
               registry()
             )

    assert duplicate.message == "duplicate component name"

    assert {:error, %Error.Invalid{errors: [required]}} =
             Codec.diagnose(stored([stored_step("one", [])], nil), registry())

    assert required.message == "Flow output is required"
    assert required.details.path == ["output"]
  end

  test "all component expression fields contribute static dependencies" do
    ref = fn name -> Ref.result(name) end

    components = [
      Step.new!(name: "step", action: ProbeAction, params: ref.("dep_step")),
      Subflow.new!(name: "child", flow: NestedFlow, params: ref.("dep_child")),
      Choice.new!(
        name: "choice",
        options: [
          Choice.Option.new!(
            name: "yes",
            action: ProbeAction,
            condition: Condition.any([true, Condition.eq(ref.("dep_condition"), 1)]),
            params: ref.("dep_option")
          )
        ],
        fallback: [action: ProbeAction, params: ref.("dep_fallback")]
      ),
      FlowMap.new!(
        name: "mapped",
        action: ProbeAction,
        collection: ref.("dep_collection"),
        params: [Ref.item(), ref.("dep_map_params")]
      ),
      Reduce.new!(
        name: "reduced",
        action: ProbeAction,
        collection: ref.("dep_reduce_collection"),
        initial: ref.("dep_reduce_initial"),
        params: [Ref.accumulator(), ref.("dep_reduce_params")]
      ),
      Iterate.new!(
        name: "iterated",
        action: ProbeAction,
        params: [Ref.state(), ref.("dep_iterate_params")],
        state: [
          schema: [],
          initial: ref.("dep_initial"),
          update: [Ref.body_result(), ref.("dep_update")]
        ],
        completion: Condition.eq(Ref.iteration_index(), ref.("dep_completion")),
        max_iterations: 1
      )
    ]

    dependencies = [
      "dep_step",
      "dep_child",
      "dep_condition",
      "dep_option",
      "dep_fallback",
      "dep_collection",
      "dep_map_params",
      "dep_reduce_collection",
      "dep_reduce_initial",
      "dep_reduce_params",
      "dep_iterate_params",
      "dep_initial",
      "dep_update",
      "dep_completion"
    ]

    producers = Enum.map(dependencies, &step(&1, []))
    flow = Flow.new!(name: "graph", components: producers ++ components, output: %{})
    assert {:ok, document} = Codec.encode(flow, registry())
    document = %{document | "components" => Enum.drop(document["components"], length(producers))}
    assert {:error, %Error.Invalid{errors: errors}} = Codec.diagnose(document, registry())
    assert Enum.sort(Enum.map(errors, & &1.details.component)) == Enum.sort(dependencies)
    assert Enum.all?(errors, &(&1.message == "Flow reference points to an unknown component"))

    assert {:error, %{details: %{component: "dep_step"}}} =
             Flow.validate(%{flow | components: components})
  end

  test "Dispatch checks use graph sinks and the complete result" do
    dispatch = Dispatch.new!(name: "next", decision: ProbeAction, expander: ProbeAction)
    flow = Flow.new!(name: "graph", components: [dispatch], output: Ref.result("next"))
    assert {:ok, document} = Codec.encode(flow, registry())
    [stored_dispatch] = document["components"]

    invalid = %{
      document
      | "components" => [stored_dispatch, stored_step("independent", [])],
        "output" => [stored_ref("next")]
    }

    assert {:error, %Error.Invalid{errors: errors}} = Codec.diagnose(invalid, registry())

    assert Enum.map(errors, &{&1.message, &1.details.path}) == [
             {"Dispatch must be the final component in the Flow", ["components", 0]},
             {"Flow output must be the complete Dispatch result", ["output"]}
           ]

    assert {:error, %{message: "Dispatch must be the final component in the Flow"}} =
             Flow.new(
               name: "graph",
               components: [dispatch, step("independent", [])],
               output: [Ref.result("next")]
             )

    assert {:error, %Error.Invalid{errors: [multiple]}} =
             Codec.diagnose(
               %{
                 document
                 | "components" => [stored_dispatch, %{stored_dispatch | "name" => "second"}]
               },
               registry()
             )

    assert multiple.details.path == ["components", 1]

    assert {:error, %{message: "Dispatch must be the final component in the Flow"}} =
             Builder.new(name: "graph")
             |> Builder.dispatch("next", ProbeAction, ProbeAction, %{})
             |> Builder.step("independent", ProbeAction, %{})
             |> Builder.output([Ref.result("next")])
             |> Builder.build()

    source = """
    defmodule Jido.Flow.GraphValidationTest.NonterminalDispatch do
      use Jido.Flow, name: "graph"
      flow do
        dispatch "next", decision: #{inspect(ProbeAction)}, expander: #{inspect(ProbeAction)}, params: %{}
        step "independent", action: #{inspect(ProbeAction)}, params: %{}
        output([result("next")])
      end
    end
    """

    error =
      assert_raise CompileError, ~r/Dispatch must be the final component/, fn ->
        Code.compile_string(source, "nonterminal_dispatch.ex")
      end

    assert error.file == "nonterminal_dispatch.ex"
    assert error.line == 4
  end

  test "Dispatch parameter references precede terminal graph rules" do
    dispatch =
      Dispatch.new!(
        name: "next",
        decision: ProbeAction,
        expander: ProbeAction,
        params: Expr.new!(:all, [false, Ref.result("missing")])
      )

    assert {:error, error} = Flow.new(name: "graph", components: [dispatch], output: %{})
    assert error.details == %{owner: "next", component: "missing"}

    flow =
      Flow.new!(
        name: "graph",
        components: [step("missing", []), dispatch],
        output: Ref.result("next")
      )

    assert {:ok, document} = Codec.encode(flow, registry())

    assert {:error, %Error.Invalid{errors: [error]}} =
             Codec.diagnose(%{document | "components" => tl(document["components"])}, registry())

    assert error.details == %{owner: "next", component: "missing", path: ["components", 0]}
  end

  test "missing references and cycles identify their source declaration" do
    cases = [
      {"missing_component",
       ~s|step "one", action: #{inspect(ProbeAction)}, params: %{}, after: ["absent"]|,
       ~s|output(result("one"))|, 4},
      {"missing_output", ~s|step "one", action: #{inspect(ProbeAction)}, params: %{}|,
       ~s|output(result("absent"))|, 5},
      {"self_cycle", ~s|step "one", action: #{inspect(ProbeAction)}, params: %{}, after: ["one"]|,
       ~s|output(result("one"))|, 4}
    ]

    for {name, declaration, output, line} <- cases do
      module = Module.concat(__MODULE__, name)

      source =
        "defmodule #{inspect(module)} do\nuse Jido.Flow, name: #{inspect(name)}\nflow do\n#{declaration}\n#{output}\nend\nend"

      file = name <> ".ex"
      error = assert_raise CompileError, fn -> Code.compile_string(source, file) end
      assert error.file == file
      assert error.line == line
    end
  end

  test "a duplicate across component kinds points to the second occurrence" do
    source = """
    defmodule Jido.Flow.GraphValidationTest.CrossKindDuplicate do
      use Jido.Flow, name: "cross_kind_duplicate"
      flow do
        step "same", action: #{inspect(ProbeAction)}, params: %{}
        map "same", collection: [], action: #{inspect(ProbeAction)}, params: %{}
        reduce "same", collection: [], initial: %{}, action: #{inspect(ProbeAction)}, params: %{}
        output(result("same"))
      end
    end
    """

    error =
      assert_raise CompileError, ~r/duplicate component name/, fn ->
        Code.compile_string(source, "cross_kind_duplicate.ex")
      end

    assert error.file == "cross_kind_duplicate.ex"
    assert error.line == 5
  end

  test "unloaded targets remain valid for inert construction and decoding" do
    component = Step.new!(name: "one", action: NotLoadedAction, params: Expr.new!(:add, [1, 2]))

    assert {:ok, flow} =
             Flow.new(name: "graph", components: [component], output: Ref.result("one"))

    assert {:ok, ^flow} = Flow.validate(flow)

    registry =
      Registry.new!(%{"unloaded" => {:action, NotLoadedAction}, "schema" => {:schema, []}})

    assert {:ok, document} = Codec.encode(flow, registry)
    assert {:ok, ^flow} = Codec.diagnose(document, registry)
  end
end
