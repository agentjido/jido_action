defmodule Jido.DocumentationTest do
  use ExUnit.Case, async: true

  @expected_groups [
    {:"Action API", [Jido.Action, Jido.Action.Output, Jido.Instruction]},
    {:"Flow API", [Jido.Flow, Jido.Flow.Builder, Jido.Flow.Registry]},
    {:"Flow Types",
     [
       Jido.Flow.Choice,
       Jido.Flow.Condition,
       Jido.Flow.Iterator,
       Jido.Flow.Map,
       Jido.Flow.Node,
       Jido.Flow.Reduce,
       Jido.Flow.Ref,
       Jido.Flow.State
     ]},
    {:Execution, [Jido.Exec, Jido.Exec.Execution, Jido.Exec.NodeResult]},
    {:Errors,
     [
       Jido.Action.Error,
       Jido.Action.Error.ConfigurationError,
       Jido.Action.Error.ExecutionFailureError,
       Jido.Action.Error.InternalError,
       Jido.Action.Error.InvalidInputError,
       Jido.Action.Error.TimeoutError
     ]}
  ]

  @internal_modules [Jido.Flow.Compiler]

  @public_builder_helpers [
    {:accumulator, 1},
    {:body_result, 1},
    {:context, 1},
    {:input, 1},
    {:item, 1},
    {:item_id, 0},
    {:item_index, 0},
    {:iteration_index, 0},
    {:result, 2},
    {:select, 2},
    {:state, 1},
    {:value, 1}
  ]

  @public_builder_types [:choice_fallback, :choice_option, :condition, :expression]

  @public_flow_validation_helpers [
    {:to_stored_map, 3},
    {:from_stored_map, 2},
    {:validate, 1},
    {:validate_executable, 1}
  ]

  test "the module index contains only supported public modules" do
    groups = Mix.Project.config()[:docs][:groups_for_modules]

    assert groups == @expected_groups
    assert visible_jido_modules() -- List.flatten(Keyword.values(groups)) == []
  end

  test "Flow implementation modules are hidden from generated documentation" do
    for module <- @internal_modules do
      assert module_doc(module) == :hidden
    end
  end

  test "removed syntax modules are not available" do
    refute Code.ensure_loaded?(Jido.Flow.Syntax)
    refute Code.ensure_loaded?(Jido.Flow.Syntax.Lowerer)
  end

  test "the internal telemetry helper uses the Action namespace" do
    assert Code.ensure_loaded?(Jido.Action.Telemetry)
    refute Code.ensure_loaded?(Jido.Telemetry)
  end

  test "runtime Builder reference helpers are visible in the API reference" do
    for {name, arity} <- @public_builder_helpers do
      assert is_map(function_doc(Jido.Flow.Builder, name, arity)),
             "expected Jido.Flow.Builder.#{name}/#{arity} to have public documentation"
    end
  end

  test "runtime Builder types are visible in the API reference" do
    assert {:ok, types} = Code.Typespec.fetch_types(Jido.Flow.Builder)

    type_names =
      Enum.map(types, fn {_kind, {name, _definition, _arguments}} -> name end)

    assert Enum.sort(@public_builder_types) == Enum.sort(type_names -- [:t])
  end

  test "Flow validation helpers are visible in the API reference" do
    for {name, arity} <- @public_flow_validation_helpers do
      assert is_map(function_doc(Jido.Flow, name, arity)),
             "expected Jido.Flow.#{name}/#{arity} to have public documentation"
    end
  end

  test "public module documentation does not expose internal release language" do
    for module <- [Jido.Flow, Jido.Exec] do
      doc = module |> module_doc() |> Map.fetch!("en")

      refute doc =~ "v4"
      refute doc =~ "later implementation units"
    end
  end

  test "unsupported runtime Action constructors stay out of the API reference" do
    assert function_doc(Jido.Action, :new, 0) == :hidden
    assert function_doc(Jido.Action, :new, 1) == :hidden
  end

  test "the Hex package contains every documentation source" do
    package_files = Mix.Project.config()[:package][:files]

    assert "README.md" in package_files
    assert "CHANGELOG.md" in package_files
    assert "LICENSE" in package_files
    assert "guides" in package_files
  end

  test "the README presents all supported Flow construction paths" do
    readme = File.read!("README.md")

    assert readme =~ "defmodule MyApp.Actions.Notify"

    for entry_point <- [
          "Jido.Flow.Builder",
          "Jido.Flow.from_stored_map",
          "Jido.Flow.Registry",
          "flow do",
          "Jido.Exec.start"
        ] do
      assert readme =~ entry_point
    end
  end

  test "published documentation does not use removed Flow terms" do
    paths = ["README.md", "usage-rules.md" | Path.wildcard("guides/*")]
    removed_terms = ["contract bundle", "Jido.Flow.Syntax", "Jido.Telemetry"]

    for path <- paths,
        term <- removed_terms do
      contents = path |> File.read!() |> String.downcase()

      refute contents =~ String.downcase(term),
             "expected #{path} not to contain removed term #{inspect(term)}"
    end
  end

  test "published telemetry documentation uses semantic Action events" do
    paths = ["README.md", "guides/execution.md", "guides/flow-execution.livemd"]

    for path <- paths do
      contents = File.read!(path)
      assert contents =~ "[:jido, :action, :start]"
      refute contents =~ "[:jido, :exec, :start]"
    end

    exec_doc = Jido.Exec |> module_doc() |> Map.fetch!("en")
    assert exec_doc =~ "[:jido, :action, :start]"
    refute exec_doc =~ "[:jido, :exec, :start]"
  end

  test "release metadata points at the release tag" do
    project = Mix.Project.config()
    version = project[:version]

    assert version == "3.0.0-rc.1"
    assert project[:docs][:source_ref] == "v#{version}"
    assert project[:package][:links]["Changelog"] =~ "/blob/v#{version}/CHANGELOG.md"
  end

  test "release checks have a coverage floor and non-interactive docs" do
    project = Mix.Project.config()

    assert project[:test_coverage][:summary][:threshold] >= 90
    refute Keyword.has_key?(project[:aliases], :docs)
    assert "credo --min-priority high" in project[:aliases][:quality]

    ci = File.read!(".github/workflows/ci.yml")
    assert ci =~ "credo_command: mix credo --min-priority high"
    assert ci =~ "docs_command: mix docs --warnings-as-errors"
    assert ci =~ "test_command: mix test --cover"
    assert ci =~ "- v3-spike"
  end

  test "usage rules cover each primary developer entry point" do
    usage_rules = File.read!("usage-rules.md")

    for module <- ["Jido.Action", "Jido.Instruction", "Jido.Flow", "Jido.Exec"] do
      assert usage_rules =~ "`#{module}`"
    end
  end

  defp visible_jido_modules do
    :jido_action
    |> Application.spec(:modules)
    |> Enum.filter(&String.starts_with?(Atom.to_string(&1), "Elixir.Jido."))
    |> Enum.reject(&(module_doc(&1) in [:hidden, :none]))
  end

  defp module_doc(module) do
    {:docs_v1, _, _, _, module_doc, _, _} = Code.fetch_docs(module)
    module_doc
  end

  defp function_doc(module, name, arity) do
    {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(module)

    case Enum.find(docs, &match?({{:function, ^name, ^arity}, _, _, _, _}, &1)) do
      {{:function, ^name, ^arity}, _, _, doc, _} -> doc
      nil -> :none
    end
  end
end
