defmodule Jido.DocumentationTest do
  use ExUnit.Case, async: true

  @expected_groups [
    {:"Action API", [Jido.Action, Jido.Action.Output, Jido.Instruction]},
    {:"Flow API", [Jido.Flow, Jido.Flow.Builder, Jido.Flow.ContractBundle]},
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

  @internal_modules [Jido.Flow.Compiler, Jido.Flow.Syntax, Jido.Flow.Syntax.Lowerer]

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
