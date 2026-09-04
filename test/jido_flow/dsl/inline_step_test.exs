defmodule Jido.Flow.DSL.InlineStepTest do
  use ExUnit.Case, async: false

  alias Jido.Flow.DSL.{Expression, InlineStep}
  alias Jido.Flow.Ref

  @source_file "inline_header.ex"
  @source_line 40

  defmodule NameSource do
    defmacro literal_name do
      send(self(), :inline_name_macro_expanded)
      "macro_name"
    end

    def expression_name do
      send(self(), :inline_name_expression_evaluated)
      "expression_name"
    end
  end

  test "legacy Step names expand or evaluate once" do
    for {expression, marker, name} <- [
          {"#{inspect(NameSource)}.literal_name()", :inline_name_macro_expanded, "macro_name"},
          {"#{inspect(NameSource)}.expression_name()", :inline_name_expression_evaluated,
           "expression_name"}
        ] do
      owner = unique_owner("LegacyName")

      declaration =
        "step #{expression}, action: JidoActionTest.Fixtures.Actions.Add, params: %{value: 1}"

      compile_source(flow_source(owner, declaration, "require #{inspect(NameSource)}"))
      assert_received ^marker
      refute_received ^marker
      assert owner.step_action(name) == JidoActionTest.Fixtures.Actions.Add
    end
  end

  test "a dynamic explicit name is registered before a later inline declaration" do
    owner = unique_owner("DynamicDuplicate")
    {target, _} = generated_identity(owner, "expression_name")

    source = """
    defmodule #{inspect(owner)} do
      use Jido.Flow, name: "dynamic_duplicate"
      flow do
        step #{inspect(NameSource)}.expression_name(), action: JidoActionTest.Fixtures.Actions.Add, params: %{value: 1}
        step "expression_name", [], do: {:ok, %{}}
        output(%{})
      end
    end
    """

    error =
      assert_raise CompileError, ~r/duplicate Step name: "expression_name"/, fn ->
        compile_source(source)
      end

    assert error.line == 5
    assert_received :inline_name_expression_evaluated
    refute_received :inline_name_expression_evaluated
    refute Code.ensure_loaded?(target)
  end

  test "a Step in a false authoring branch does not reserve its name" do
    for unused <- [
          ~s(step "same", action: JidoActionTest.Fixtures.Actions.Add, params: %{value: 1}),
          ~s(step "same", [], do: {:ok, %{value: :unused}})
        ] do
      owner = unique_owner("Conditional")

      declarations = """
      if false do
        #{unused}
      end
      step "same", [], do: {:ok, %{value: :used}}
      """

      compile_source(flow_source(owner, declarations))
      assert [%Jido.Flow.Step{name: "same"}] = owner.flow().components
      assert owner.step_action("same").run(%{}, %{}) == {:ok, %{value: :used}}
    end
  end

  test "duplicate Steps fail before a second inline target can replace the first" do
    inline = ~s(step :same, [], do: {:ok, %{value: :first}})
    replacement = ~s(step "same", [], do: {:ok, %{value: :second}})
    keyword = ~s(step "same", action: JidoActionTest.Fixtures.Actions.Add, params: %{value: 1})

    block =
      "step \"same\" do\n action(JidoActionTest.Fixtures.Actions.Add)\n params(%{value: 1})\n end"

    for {first, second} <- [
          {inline, replacement},
          {inline, keyword},
          {keyword, inline},
          {inline, block},
          {block, inline}
        ] do
      owner = unique_owner("Duplicate")
      target = generated_identity(owner, "same") |> elem(0)

      assert_raise CompileError, ~r/duplicate Step name: "same"/, fn ->
        compile_source(flow_source(owner, first <> "\n" <> second))
      end

      if first == inline do
        assert target.__jido_inline_step__() == {owner, "same"}
      else
        refute Code.ensure_loaded?(target)
      end
    end
  end

  test "foreign generated module names cannot be overwritten" do
    owner = unique_owner("Foreign")
    {target, _function} = generated_identity(owner, "same")
    compile_source("defmodule #{inspect(target)} do\n def untouched, do: :foreign\nend")

    assert_raise CompileError, ~r/generated inline Step module.*already belongs/, fn ->
      compile_source(flow_source(owner, ~s(step "same", [], do: {:ok, %{}})))
    end

    assert target.untouched() == :foreign
    refute function_exported?(target, :run, 2)
  end

  test "generated owner functions and lookup reject user clauses before and after declarations" do
    for position <- [:before, :after], kind <- [:body, :lookup], visibility <- [:def, :defp] do
      owner = unique_owner("Reserved")
      {_target, body_function} = generated_identity(owner, "same")
      {function, args} = if kind == :body, do: {body_function, "_, _"}, else: {:step_action, "_"}
      clause = "#{visibility} #{function}(#{args}), do: :user_clause"
      declaration = ~s(step "same", [], do: {:ok, %{}})
      {before, after_code} = if position == :before, do: {clause, ""}, else: {"", clause}

      # Elixir itself rejects a private clause after a public generated body
      # before it calls the definition callback.
      message =
        if position == :after and kind == :body and visibility == :defp,
          do: ~r/cannot compile file|already defined as def/,
          else: ~r/reserved Flow function.*#{function}/

      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert_raise CompileError, message, fn ->
          compile_source(flow_source(owner, declaration, before, after_code))
        end
      end)
    end
  end

  test "lookup is reserved even when it is defined before use Jido.Flow" do
    owner = unique_owner("EarlyLookup")

    assert_raise CompileError, ~r/reserved Flow function.*step_action/, fn ->
      compile_source("""
      defmodule #{inspect(owner)} do
        def step_action(_), do: :user_clause
        use Jido.Flow, name: "early_lookup"
        flow do
          step "same", action: JidoActionTest.Fixtures.Actions.Add
          output(%{})
        end
      end
      """)
    end
  end

  test "bounded target names preserve long, punctuation, and Unicode names across owners" do
    names = [String.duplicate("x", 256), "hello-world?!", "café/世界"]
    owner = unique_owner(String.duplicate("L", 150))
    other = unique_owner("Other")
    declarations = Enum.map_join(names, "\n", &"step #{inspect(&1)}, [], do: {:ok, %{}}")
    compile_source(flow_source(owner, declarations))
    compile_source(flow_source(other, declarations))

    for name <- names do
      target = owner.step_action(name)
      assert target != other.step_action(name)
      assert byte_size(Atom.to_string(target)) < 128
      assert target.name() == name
      assert target.__jido_inline_step__() == {owner, name}
    end
  end

  test "normal recompilation keeps identity and replaces the body" do
    owner = unique_owner("Recompiled")
    compile_source(flow_source(owner, ~s(step "same", [], do: {:ok, %{version: 1}})))
    target = owner.step_action("same")

    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      compile_source(flow_source(owner, ~s(step "same", [], do: {:ok, %{version: 2}})))
    end)

    assert owner.step_action("same") == target
    assert target.run(%{}, %{}) == {:ok, %{version: 2}}
  end

  test "repeated runtime access creates no target modules or atoms from unknown names" do
    owner = JidoActionTest.Fixtures.InlineGreetingFlow

    unknown_names =
      for n <- 1..100, do: "unknown_inline_step_#{n}_#{System.unique_integer([:positive])}"

    access = fn ->
      for name <- unknown_names do
        assert_raise ArgumentError, fn -> owner.step_action(name) end
      end

      assert is_atom(owner.step_action(:greet))
      assert {:ok, _} = Jido.Flow.validate(owner.flow())
      assert {:ok, _} = Jido.Exec.run(owner, %{name: "Ada"})
    end

    access.()
    targets = generated_modules()
    atoms = :erlang.system_info(:atom_count)
    for _ <- 1..3, do: access.()
    assert :erlang.system_info(:atom_count) == atoms
    assert generated_modules() == targets

    for name <- unknown_names do
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end
  end

  test "inline bindings compile and run through ordinary Steps with inferred dependencies" do
    assert [%Jido.Flow.Step{action: action, params: params}, %Jido.Flow.Step{}] =
             JidoActionTest.Fixtures.InlineGreetingFlow.flow().components

    assert is_atom(action)
    assert params == %{name: Ref.input(:name)}

    assert Jido.Exec.run(JidoActionTest.Fixtures.InlineGreetingFlow, %{name: " Ada "}) ==
             {:ok, %{message: "Hello, Ada!"}}

    assert {:ok, dependencies} =
             Jido.Flow.dependencies(JidoActionTest.Fixtures.InlineGreetingFlow.flow())

    assert dependencies["greet"] == %{
             after: [],
             references: ["normalize"],
             effective: ["normalize"]
           }
  end

  test "bodies retain the declaration's aliases, imports, helpers, module, and attributes" do
    module = JidoActionTest.Fixtures.InlineLexicalFlow
    assert {:ok, result} = Jido.Exec.run(module, %{name: " Ada "})

    assert result == %{
             value: "[ADA!?]",
             module: module,
             prefix: "before",
             qualified: %{name: "body", value: " Ada "},
             local_import: %{name: "local", value: "[ADA!?]"}
           }

    assert module.current_prefix() == "after"
    assert Enum.map(module.flow().components, & &1.name) == ["lexical", "local_import"]
  end

  for namespace <- [Jido.Flow.DSLHelpers, Spark.DslHelpers] do
    test "inline bodies retain imports from #{inspect(namespace)}" do
      helper = Module.concat(unquote(namespace), "Inline#{System.unique_integer([:positive])}")
      owner = unique_owner("SimilarNamespace")

      on_exit(fn ->
        :code.purge(helper)
        :code.delete(helper)
      end)

      compile_source("""
      defmodule #{inspect(helper)} do
        def prefix_marker, do: :retained
      end
      """)

      declaration = ~s|step "same", [], do: {:ok, %{marker: prefix_marker()}}|
      compile_source(flow_source(owner, declaration, "import #{inspect(helper)}"))

      assert owner.step_action("same").run(%{}, %{}) == {:ok, %{marker: :retained}}
      assert [%Jido.Flow.Step{name: "same"}] = owner.flow().components
    end
  end

  test "canonical inline Steps contain only ordinary Action author data" do
    flow = JidoActionTest.Fixtures.InlineGreetingFlow.flow()
    map = Jido.Flow.to_map(flow)

    for step <- flow.components do
      assert Map.keys(Map.from_struct(step)) |> Enum.sort() ==
               [:action, :after, :meta, :name, :params]

      assert is_atom(step.action)
      assert step.action.name() == step.name
      assert step.action.schema() == []
      assert step.action.output_schema() == []
    end

    assert canonical_data?(map)
  end

  test "compiler, validation, and inspection do not run inline work" do
    source = """
    defmodule Jido.Flow.DSL.InlineStepTest.InertFlow do
      use Jido.Flow, name: "inline_inert"
      flow do
        step "mark", ctx <- context() do
          send(ctx.owner, {:inline_work, ctx.marker})
          {:ok, %{worked: true}}
        end
        output(result("mark"))
      end
    end
    """

    compile_source(source)
    module = Module.concat(__MODULE__, InertFlow)
    flow = module.flow()
    assert {:ok, ^flow} = Jido.Flow.validate(flow)
    assert {:ok, ^flow} = Jido.Flow.validate_executable(flow)
    assert {:ok, _} = Jido.Flow.explain(flow)
    assert {:ok, _} = Jido.Flow.compile(flow)
    assert is_map(Jido.Flow.to_map(flow))
    refute_received {:inline_work, _}

    marker = make_ref()
    assert {:ok, %{worked: true}} = Jido.Exec.run(module, %{}, %{owner: self(), marker: marker})
    assert_received {:inline_work, ^marker}
  end

  test "undefined body calls report the user body file and line" do
    source = """
    defmodule Jido.Flow.DSL.InlineStepTest.UndefinedFlow do
      use Jido.Flow, name: "inline_undefined"
      flow do
        step "bad", [] do
          missing_inline_function()
        end
        output(result("bad"))
      end
    end
    """

    {_result, diagnostics} =
      Code.with_diagnostics(fn ->
        assert_raise CompileError, fn -> compile_source(source, "inline_undefined.ex") end
      end)

    assert Enum.any?(diagnostics, fn diagnostic ->
             diagnostic.severity == :error and
               diagnostic.message =~ "undefined function missing_inline_function/0" and
               Path.basename(diagnostic.file) == "inline_undefined.ex" and
               diagnostic_line(diagnostic) == 5
           end)
  end

  test "declaration imports are not available inside the body function" do
    source = """
    defmodule Jido.Flow.DSL.InlineStepTest.NoDeclarationFlow do
      use Jido.Flow, name: "inline_no_declaration"
      flow do
        step "bad", [] do
          output(%{})
        end
        output(result("bad"))
      end
    end
    """

    {_result, diagnostics} =
      Code.with_diagnostics(fn ->
        assert_raise CompileError, fn -> compile_source(source, "inline_no_declaration.ex") end
      end)

    assert Enum.any?(diagnostics, fn diagnostic ->
             diagnostic.severity == :error and diagnostic.message =~ "undefined function output/1" and
               diagnostic_line(diagnostic) == 5
           end)
  end

  test "unused user variables retain warnings at the header line" do
    source = """
    defmodule Jido.Flow.DSL.InlineStepTest.UnusedFlow do
      use Jido.Flow, name: "inline_unused"
      flow do
        step "unused", user_value <- input(:value) do
          body_value = :unused
          {:ok, %{}}
        end
        output(result("unused"))
      end
    end
    """

    {_modules, diagnostics} =
      Code.with_diagnostics(fn -> compile_source(source, "inline_unused.ex") end)

    assert Enum.any?(diagnostics, fn diagnostic ->
             diagnostic.severity == :warning and diagnostic.message =~ "user_value" and
               diagnostic.message =~ "unused" and
               Path.basename(diagnostic.file) == "inline_unused.ex" and
               diagnostic_line(diagnostic) == 4
           end)

    assert Enum.any?(diagnostics, fn diagnostic ->
             diagnostic.severity == :warning and diagnostic.message =~ "body_value" and
               Path.basename(diagnostic.file) == "inline_unused.ex" and
               diagnostic_line(diagnostic) == 5
           end)
  end

  test "all inline macro arities lower their params, after, and meta through normal Steps" do
    source = """
    defmodule Jido.Flow.DSL.InlineStepTest.BindingFormsFlow do
      use Jido.Flow, name: "inline_binding_forms"
      alias URI, as: Address

      flow do
        step :seed, [] do
          {:ok, %{ready: true}}
        end

        step "one", name <- input(:name), after: ["seed"], meta: %{form: "one"} do
          {:ok, %{name: name}}
        end

        step "two", name <- result("one", :name), ctx <- context() do
          {:ok, %{name: name <> ctx.suffix}}
        end

        step "two_options", name <- result("two", :name), count <- input(:count),
          after: ["seed"], meta: %{form: "two"} do
          {:ok, %{name: name, count: count}}
        end

        step "list", [name <- result("two_options", :name), count <- input(:count), ctx <- context()],
          meta: %{form: "list"} do
          repeat = fn value -> String.duplicate(value, count) end
          {:ok, %{name: repeat.(name), suffix: ctx.suffix}}
        end

        step "pattern", %{uri: %Address{path: path}, kind: :person} <- input() do
          {:ok, %{path: path}}
        end

        output(%{list: result("list"), path: result("pattern", :path)})
      end
    end
    """

    compile_source(source)
    module = Module.concat(__MODULE__, BindingFormsFlow)
    assert [seed, one, two, two_options, list, pattern] = module.flow().components
    assert seed.name == "seed"
    assert seed.params == %{}
    assert one.after == ["seed"]
    assert one.meta == %{form: "one"}
    assert two.params == %{name: Ref.result("one", :name), ctx: Ref.context()}
    assert two_options.after == ["seed"]
    assert two_options.meta == %{form: "two"}
    assert list.meta == %{form: "list"}
    assert pattern.params == Ref.input([])

    assert Jido.Exec.run(
             module,
             %{name: "Ada", count: 2, uri: URI.parse("/home"), kind: :person},
             %{suffix: "!"}
           ) ==
             {:ok, %{list: %{name: "Ada!Ada!", suffix: "!"}, path: "/home"}}
  end

  test "a runtime raise keeps the user body file and line" do
    source = """
    defmodule Jido.Flow.DSL.InlineStepTest.RaisingFlow do
      use Jido.Flow, name: "inline_raising"
      flow do
        step "raise", [] do
          raise "inline body failed"
        end
        output(result("raise"))
      end
    end
    """

    compile_source(source, "inline_raise.ex")
    assert {:error, error} = Jido.Exec.run(__MODULE__.RaisingFlow)
    assert %Splode.Stacktrace{stacktrace: stacktrace} = error.stacktrace

    assert Enum.any?(stacktrace, fn
             {__MODULE__.RaisingFlow, _function, _arity, location} ->
               to_string(location[:file]) == "inline_raise.ex" and location[:line] == 5

             _frame ->
               false
           end)
  end

  test "normal invalid nested patterns are rejected by the owner function compiler" do
    source = """
    defmodule Jido.Flow.DSL.InlineStepTest.BadPatternFlow do
      use Jido.Flow, name: "inline_bad_pattern"
      flow do
        step "bad", %{name: String.trim(name)} <- input() do
          {:ok, %{name: name}}
        end
        output(result("bad"))
      end
    end
    """

    {_result, diagnostics} =
      Code.with_diagnostics(fn ->
        assert_raise CompileError, fn -> compile_source(source, "inline_pattern.ex") end
      end)

    assert Enum.any?(diagnostics, fn diagnostic ->
             diagnostic.severity == :error and diagnostic.message =~ "inside a match" and
               Path.basename(diagnostic.file) == "inline_pattern.ex" and
               diagnostic_line(diagnostic) == 4
           end)
  end

  test "one named binding retains the input and body syntax" do
    {:step, _, [_name, binding, options]} =
      ast("step :greet, name <- input(:name), do: {:ok, %{name: name}}")

    parsed = InlineStep.parse!(binding, options, caller())
    {:<-, _, [variable, source]} = binding

    assert parsed.params_ast == {:%{}, [line: @source_line], [name: source]}
    assert parsed.pattern_ast == {:%{}, [line: @source_line], [name: variable]}
    assert parsed.body_ast == options[:do]
    assert parsed.options == []
    assert parsed.source == %{file: @source_file, line: @source_line}
    assert Expression.parse(parsed.params_ast) == {:ok, %{name: Ref.input(:name)}}
  end

  test "two bare bindings and larger binding lists use named atom keys" do
    two = parse("step :sum, left <- input(:left), right <- result(:load), do: :ok")
    list = parse("step :sum, [a <- input(), b <- context(), _c <- value(3)], do: :ok")

    assert Expression.parse(two.params_ast) ==
             {:ok, %{left: Ref.input(:left), right: Ref.result(:load)}}

    assert Macro.to_string(two.pattern_ast) == "%{left: left, right: right}"

    assert Expression.parse(list.params_ast) ==
             {:ok, %{a: Ref.input([]), b: Ref.context([]), _c: 3}}

    assert Macro.to_string(list.pattern_ast) == "%{a: a, b: b, _c: _c}"
  end

  test "a sole map pattern retains nested matches and uses the whole source as params" do
    source = """
    step :read,
      %{"user" => %{name: name}, :kind => :person, 1 => {head, [first | rest]}} <- input(),
      do: {:ok, %{name: name, head: head, first: first, rest: rest}}
    """

    {:step, _, [_name, {:<-, _, [pattern, params]}, options]} = ast(source)
    parsed = parse(source)

    assert parsed.pattern_ast == pattern
    assert parsed.params_ast == params
    assert parsed.body_ast == options[:do]
    assert Expression.parse(parsed.params_ast) == {:ok, Ref.input([])}

    list = parse("step :read, [%{name: name} <- result(:load)], do: name")
    assert Macro.to_string(list.pattern_ast) == "%{name: name}"
    assert Expression.parse(list.params_ast) == {:ok, Ref.result(:load)}
  end

  test "an explicit empty binding list produces empty params and a map pattern" do
    parsed = parse("step :ready, [], do: {:ok, %{ready: true}}")

    assert parsed.params_ast == {:%{}, [line: @source_line], []}
    assert parsed.pattern_ast == {:%{}, [line: @source_line], []}
  end

  test "all header forms retain after and meta options without body evaluation" do
    marker = :inline_body_ran
    body = quote do: send(self(), unquote(marker))

    option_sets = [
      [],
      [after: [:first]],
      [meta: %{owner: :test}],
      [after: [:first], meta: %{owner: :test}]
    ]

    for header <- [
          "name <- input()",
          "left <- input(), right <- context()",
          "[a <- input(), b <- context(), c <- 3]",
          "[]"
        ],
        options <- option_sets do
      {:step, _, [_name | arguments]} = ast("step :read, #{header}, do: :ok")
      arguments = List.replace_at(arguments, -1, options ++ [do: body])
      parsed = apply(InlineStep, :parse!, arguments ++ [caller()])

      assert parsed.options == options
      assert parsed.body_ast == body
    end

    refute_received ^marker
  end

  test "body functions and nested after clauses remain normal Elixir syntax" do
    source = """
    step :read, names <- input(:names), after: [:load] do
      try do
        cleaner = fn name -> String.trim(name) end
        {:ok, %{names: Enum.map(names, cleaner)}}
      after
        cleanup()
      end
    end
    """

    {:step, _, [_name, _binding, _header_options, options]} = ast(source)
    parsed = parse(source)

    assert parsed.options == [after: [:load]]
    assert parsed.body_ast == options[:do]
    assert Macro.to_string(parsed.body_ast) =~ "after"
  end

  test "native do blocks keep separate header options for all binding forms" do
    for header <- [
          "name <- input()",
          "left <- input(), right <- context()",
          "[a <- input(), b <- context(), c <- 3]",
          "[]"
        ],
        options <- [
          "after: [:load]",
          "meta: %{owner: :test}",
          "after: [:load], meta: %{owner: :test}"
        ] do
      source = "step :read, #{header}, #{options} do\n  {:ok, %{}}\nend"
      {:step, _, arguments} = ast(source)
      parsed = parse(source)

      assert parsed.options == Enum.at(arguments, -2)
      assert Macro.to_string(parsed.body_ast) == "{:ok, %{}}"
    end
  end

  test "split header and body options reject duplicate fields" do
    assert_raise CompileError, ~r/duplicate inline Step field: :after/, fn ->
      InlineStep.parse!([], [after: [:one]], [after: [:two], do: :ok], caller())
    end
  end

  test "invalid bindings fail at the source declaration" do
    cases = [
      {"[name <- input(), name <- context()]", ~r/duplicate inline Step binding: :name/},
      {"[%{name: name} <- input(), other <- context()]", ~r/map pattern must be the only/},
      {"[%{name: name} <- input(), %{other: other} <- context()]",
       ~r/map pattern must be the only/},
      {"%User{name: name} <- input()", ~r/struct patterns are not supported/},
      {"^name <- input()", ~r/pinned variables are not supported/},
      {"%{name: ^name} <- input()", ~r/pinned variables are not supported/},
      {"(name when is_binary(name)) <- input()", ~r/guards are not supported/},
      {"_ <- input()", ~r/bare _ binding is not supported/},
      {"[name <- input(), :bad]", ~r/expected a binding/},
      {"[name: input()]", ~r/expected a binding/},
      {"[name <- input() | rest]", ~r/unsupported Flow expression/},
      {"{left, right} <- input()", ~r/named variable or a sole map pattern/},
      {"%{key => value} <- input()", ~r/map pattern keys must be literals/},
      {"%{name: name, name: other} <- input()", ~r/duplicate inline Step map key: :name/}
    ]

    for {header, message} <- cases do
      error =
        assert_raise CompileError, message, fn -> parse("step :read, #{header}, do: :ok") end

      assert error.file == @source_file
      assert error.line == @source_line
    end
  end

  test "binding sources use only the existing Flow expression grammar" do
    for header <- [
          "name <- String.trim(input(:name))",
          "[name <- input(), other <- name]",
          "name <- (input(:name) |> String.trim())",
          "name <- fn -> :ok end",
          "name <- %{duplicate: 1, duplicate: 2}"
        ] do
      error =
        assert_raise CompileError, ~r/inline Step binding source:.*Flow/s, fn ->
          parse("step :read, #{header}, do: :ok")
        end

      assert error.file == @source_file
      assert error.line == @source_line
    end
  end

  test "source errors retain the offending expression line" do
    error =
      assert_raise CompileError, ~r/unsupported Flow expression/, fn ->
        parse("step :read,\n  name <-\n    String.trim(input(:name)),\n  do: name")
      end

    assert error.file == @source_file
    assert error.line == @source_line + 2
  end

  test "inline options reject explicit target fields, schema fields, and unknown fields" do
    for field <- [:action, :params, :run, :schema, :output_schema, :unknown] do
      error =
        assert_raise CompileError,
                     "#{@source_file}:#{@source_line}: unsupported inline Step field: #{inspect(field)}; use only after:, meta:, and do:",
                     fn ->
                       InlineStep.parse!(
                         ast("name <- input()"),
                         [{field, :invalid}, {:do, :ok}],
                         caller()
                       )
                     end

      assert error.file == @source_file
      assert error.line == @source_line
    end
  end

  test "duplicate fields, missing bodies, and malformed options fail before parsing bindings" do
    for field <- [:after, :meta, :do] do
      assert_raise CompileError, ~r/duplicate inline Step field/, fn ->
        InlineStep.parse!([], [{field, :first}, {field, :second}, {:do, :ok}], caller())
      end
    end

    assert_raise CompileError, ~r/inline Step requires a do block/, fn ->
      InlineStep.parse!([], [after: [:first]], caller())
    end

    assert_raise CompileError, ~r/inline Step options must be a keyword list/, fn ->
      apply(InlineStep, :parse!, [[], :invalid, caller()])
    end

    assert parse("step :read, [], do: nil").body_ast == nil
  end

  test "the two bare binding form does not accept a list argument" do
    assert_raise CompileError, ~r/expected a binding/, fn ->
      InlineStep.parse!([ast("name <- input()")], ast("other <- context()"), [do: :ok], caller())
    end
  end

  test "map patterns reject nested updates, guards, and dynamic keys" do
    for pattern <- [
          "%{name: (name when is_binary(name))}",
          "%{user: %{base | name: name}}",
          "%{user: %{key => name}}"
        ] do
      assert_raise CompileError, fn ->
        parse("step :read, #{pattern} <- input(), do: :ok")
      end
    end
  end

  test "map patterns retain normal nested structs, binary matches, aliases, and matches" do
    pattern =
      "%{uri: %URI{path: path}, pair: {first, second, _}, bytes: <<head::integer, tail::binary>>, value: value = [item | _], module: String, prefix: \"x\" <> suffix}"

    source = "step :read, #{pattern} <- input(), do: :ok"
    {:step, _, [_name, {:<-, _, [pattern_ast, _]}, _]} = ast(source)
    parsed = parse(source)
    assert parsed.pattern_ast == pattern_ast
  end

  test "map patterns retain binary size references and signed literal keys" do
    source =
      "step :read, %{-1 => name, data: <<width, body::binary-size(width * 8)>>} <- input(), do: :ok"

    {:step, _, [_name, {:<-, _, [pattern_ast, _]}, _]} = ast(source)

    assert parse(source).pattern_ast == pattern_ast
  end

  defp parse(source) do
    {:step, _, [_name | arguments]} = ast(source)
    apply(InlineStep, :parse!, arguments ++ [caller()])
  end

  defp unique_owner(prefix),
    do: Module.concat(__MODULE__, "#{prefix}#{System.unique_integer([:positive])}")

  defp flow_source(owner, declarations, before_code \\ "", after_code \\ "") do
    """
    defmodule #{inspect(owner)} do
      use Jido.Flow, name: "inline_test"
      #{before_code}
      flow do
        #{declarations}
        output(%{})
      end
      #{after_code}
    end
    """
  end

  defp generated_identity(owner, name) do
    digest =
      :crypto.hash(:sha256, :erlang.term_to_binary({owner, name})) |> Base.encode16(case: :lower)

    {Module.concat(Jido.Flow.Generated.InlineStep, "A" <> digest),
     String.to_atom("__jido_inline_step_" <> digest)}
  end

  defp generated_modules do
    for {module, _} <- :code.all_loaded(),
        String.starts_with?(Atom.to_string(module), "Elixir.Jido.Flow.Generated.InlineStep."),
        into: MapSet.new(),
        do: module
  end

  defp ast(source), do: Code.string_to_quoted!(source, line: @source_line, columns: true)
  defp caller, do: %{__ENV__ | file: @source_file, line: @source_line}

  defp canonical_data?(value) when is_map(value) do
    not is_struct(value, Macro.Env) and
      Enum.all?(Map.to_list(value), fn {key, item} ->
        canonical_data?(key) and canonical_data?(item)
      end)
  end

  defp canonical_data?(value) when is_list(value), do: Enum.all?(value, &canonical_data?/1)
  defp canonical_data?(value) when is_tuple(value), do: false
  defp canonical_data?(value), do: not is_function(value)

  defp diagnostic_line(%{position: {line, _column}}), do: line
  defp diagnostic_line(%{position: line}), do: line

  defp compile_source(source, file \\ "inline_compile.ex") do
    loaded = MapSet.new(:code.all_loaded(), &elem(&1, 0))

    try do
      Code.compile_string(source, file)
    after
      owned =
        for {module, _} <- :code.all_loaded(),
            not MapSet.member?(loaded, module),
            String.starts_with?(Atom.to_string(module), [
              "Elixir.Jido.Flow.DSL.InlineStepTest.",
              "Elixir.Jido.Flow.Generated.InlineStep."
            ]),
            do: module

      on_exit(fn ->
        Enum.each(owned, fn module ->
          :code.purge(module)
          :code.delete(module)
        end)
      end)
    end
  end
end
