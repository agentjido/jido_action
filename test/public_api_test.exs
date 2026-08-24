defmodule Jido.PublicAPITest do
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
    {:Execution,
     [Jido.Exec, Jido.Exec.Execution, Jido.Exec.FlowFailureError, Jido.Exec.NodeResult]},
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

  @internal_modules [
    Jido.Exec.FlowRunnableExecutor,
    Jido.Flow.Compiler,
    Jido.Flow.Compiler.Choice,
    Jido.Flow.Compiler.Condition,
    Jido.Flow.Compiler.ErrorTagger,
    Jido.Flow.Compiler.Expression,
    Jido.Flow.Compiler.Iterator,
    Jido.Flow.Compiler.Map,
    Jido.Flow.Compiler.MapResult,
    Jido.Flow.Compiler.Reduce,
    Jido.Flow.Compiler.Target,
    Jido.Flow.Compiler.TargetContext,
    Jido.Flow.Builder.Normalizer,
    Jido.Flow.DSL.MacroSupport,
    Jido.Flow.DSL.ModuleCompiler,
    Jido.Flow.Element.Validation,
    Jido.Flow.Expression,
    Jido.Flow.Graph,
    Jido.Flow.Inspection,
    Jido.Flow.Iterator.Termination,
    Jido.Flow.MapCodec,
    Jido.Flow.MapCodec.ChoiceDecoder,
    Jido.Flow.MapCodec.CollectionDecoder,
    Jido.Flow.MapCodec.DataDecoder,
    Jido.Flow.MapCodec.DataEncoder,
    Jido.Flow.MapCodec.Decoder,
    Jido.Flow.MapCodec.Encoder,
    Jido.Flow.MapCodec.ErrorPath,
    Jido.Flow.MapCodec.ExpressionDecoder,
    Jido.Flow.MapCodec.ExpressionEncoder,
    Jido.Flow.MapCodec.IteratorDecoder,
    Jido.Flow.MapCodec.RecordValidator,
    Jido.Flow.MapCodec.RegistryLookup,
    Jido.Flow.SemanticMap,
    Jido.Flow.Runtime.OrderedTaskRunner,
    Jido.Flow.Validation
  ]

  @hidden_flow_helpers [
    {:__validate_config__, 1},
    {:canonical_nodes, 1}
  ]

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

  test "public module documentation does not expose the internal graph engine" do
    for module <- List.flatten(Keyword.values(@expected_groups)) do
      refute inspect(module_doc(module)) =~ "Runic"
    end
  end

  test "public types and function specifications do not expose the internal graph engine" do
    for module <- List.flatten(Keyword.values(@expected_groups)) do
      for rendered <- rendered_types(module) ++ rendered_specs(module) do
        refute rendered =~ "Runic"
      end
    end
  end

  test "the public Execution type does not list internal state fields" do
    assert {:ok, types} = Code.Typespec.fetch_types(Jido.Exec.Execution)
    {:type, type} = Enum.find(types, &match?({_kind, {:t, _definition, []}}, &1))

    rendered = type |> Code.Typespec.type_to_quoted() |> Macro.to_string()

    assert rendered == "t() :: struct()"
  end

  test "Flow compatibility helpers stay hidden from generated documentation" do
    for {name, arity} <- @hidden_flow_helpers do
      assert function_doc(Jido.Flow, name, arity) == :hidden
    end
  end

  test "Flow keeps its hidden before-compile compatibility macro" do
    Code.ensure_loaded!(Jido.Flow)
    assert macro_exported?(Jido.Flow, :__before_compile__, 1)
  end

  test "runtime Builder reference helpers are visible in the API reference" do
    for {name, arity} <- @public_builder_helpers do
      assert is_map(function_doc(Jido.Flow.Builder, name, arity)),
             "expected Jido.Flow.Builder.#{name}/#{arity} to have public documentation"
    end
  end

  test "runtime Builder types are visible in the API reference" do
    assert {:ok, types} = Code.Typespec.fetch_types(Jido.Flow.Builder)

    type_names = Enum.map(types, fn {_kind, {name, _definition, _arguments}} -> name end)

    assert Enum.sort(@public_builder_types) == Enum.sort(type_names -- [:t])
  end

  test "Flow validation helpers are visible in the API reference" do
    for {name, arity} <- @public_flow_validation_helpers do
      assert is_map(function_doc(Jido.Flow, name, arity)),
             "expected Jido.Flow.#{name}/#{arity} to have public documentation"
    end
  end

  test "unsupported runtime Action constructors stay out of the API reference" do
    assert function_doc(Jido.Action, :new, 0) == :hidden
    assert function_doc(Jido.Action, :new, 1) == :hidden
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

  defp rendered_types(module) do
    case Code.Typespec.fetch_types(module) do
      {:ok, types} ->
        Enum.map(types, fn {_kind, type} ->
          type |> Code.Typespec.type_to_quoted() |> Macro.to_string()
        end)

      :error ->
        []
    end
  end

  defp rendered_specs(module) do
    case Code.Typespec.fetch_specs(module) do
      {:ok, specs} ->
        Enum.flat_map(specs, fn {{name, _arity}, definitions} ->
          Enum.map(definitions, fn definition ->
            name |> Code.Typespec.spec_to_quoted(definition) |> Macro.to_string()
          end)
        end)

      :error ->
        []
    end
  end
end
