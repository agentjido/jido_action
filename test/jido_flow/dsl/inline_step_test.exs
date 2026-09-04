defmodule Jido.Flow.DSL.InlineStepTest do
  use ExUnit.Case, async: true

  alias Jido.Flow.DSL.{Expression, InlineStep}
  alias Jido.Flow.Ref

  @source_file "inline_header.ex"
  @source_line 40

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

  defp ast(source), do: Code.string_to_quoted!(source, line: @source_line, columns: true)
  defp caller, do: %{__ENV__ | file: @source_file, line: @source_line}
end
