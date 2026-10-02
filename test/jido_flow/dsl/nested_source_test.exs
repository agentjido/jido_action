defmodule Jido.Flow.DSL.NestedSourceTest.Extension do
  use Jido.Flow.Extension

  defmacro branch(name, options) do
    quote do
      option unquote(name), unquote(options)
    end
  end

  defmacro fallback(options) do
    quote do
      otherwise unquote(options)
    end
  end

  defmacro local_state(schema, options) do
    quote do
      state unquote(schema), unquote(options)
    end
  end
end

defmodule Jido.Flow.DSL.NestedSourceTest do
  use ExUnit.Case, async: false

  for debug_info <- [true, false],
      form <- [:direct, :extension],
      {kind, message} <- [
        option_scope: "flow expression contains a scoped ref outside its valid scope",
        fallback_scope: "flow expression contains a scoped ref outside its valid scope",
        option_name: "Action name cannot be blank.",
        state_schema: "iterate state schema must be a Zoi schema",
        fallback_parse:
          "unsupported Flow expression: [Date.utc_today()]; use a Flow reference, literal, map, or list",
        state_parse:
          "unsupported Flow expression: [Date.utc_today()]; use a Flow reference, literal, map, or list"
      ] do
    test "#{kind} keeps its #{form} declaration line with debug_info #{debug_info}" do
      {declarations, marker} = declarations(unquote(kind), unquote(form))
      {error, source} = compile_error(declarations, unquote(debug_info))

      line =
        source
        |> String.split("\n")
        |> Enum.find_index(&String.contains?(&1, marker))
        |> Kernel.+(1)

      assert error.description == unquote(message)
      assert error.file == "nested_source.ex"
      assert error.line == line
    end
  end

  test "Choice validation keeps parent and parse error precedence" do
    for {declarations, message} <- [
          {"""
           choice "" do
             option "selected", condition: item() == 1, action: Echo, params: %{}
             otherwise action: Echo, params: item()
           end
           output %{}
           """, "Action name cannot be blank."},
          {"""
           choice "route" do
             option "selected", condition: item() == 1, action: Echo, params: %{}
             otherwise action: Echo, params: Date.utc_today()
           end
           output %{}
           """, "unsupported Flow expression: Date.utc_today()"},
          {"""
           choice "route" do
             option "", condition: true, action: Echo, params: %{}
             otherwise action: Echo, params: item()
           end
           output %{}
           """, "Action name cannot be blank."}
        ] do
      {error, _source} = compile_error(declarations)
      assert String.starts_with?(error.description, message)
    end
  end

  test "fallback data keys do not identify a Choice option" do
    for {params, line} <- [{"%{}", 7}, {"item()", 6}] do
      {error, _source} =
        compile_error("""
        choice "route" do
          option "selected", condition: true, action: Echo, params: #{params}
          otherwise action: Echo, params: %{options: [item()]}
        end
        output result("route")
        """)

      assert error.description == "flow expression contains a scoped ref outside its valid scope"
      assert error.line == line
    end
  end

  test "Iterate validation keeps termination before State validation" do
    {error, _source} =
      compile_error("""
      iterate "loop" do
        state :invalid_schema, initial: %{}
        action Echo
        params %{}
        repeat 10001
      end
      output result("loop")
      """)

    assert error.description == "iterate repeat must be an integer from 1 to 10000"
    assert error.line == 5
  end

  test "an invalid Iterate update keeps the Iterate location" do
    {error, _source} =
      compile_error("""
      iterate "loop" do
        state [], initial: %{}
        action Echo
        params %{}
        update item()
        repeat 1
      end
      output result("loop")
      """)

    assert error.description == "flow expression contains a scoped ref outside its valid scope"
    assert error.line == 5
  end

  test "invalid State initial data precedes an invalid Iterate update" do
    {error, _source} =
      compile_error("""
      iterate "loop" do
        state [], initial: item()
        action Echo
        params %{}
        update item()
        repeat 1
      end
      output result("loop")
      """)

    assert error.description == "flow expression contains a scoped ref outside its valid scope"
    assert error.line == 6
  end

  defp declarations(kind, form) do
    option = if form == :extension, do: "branch", else: "option"
    fallback = if form == :extension, do: "fallback", else: "otherwise"
    state = if form == :extension, do: "local_state", else: "state"

    case kind do
      :option_scope ->
        {"""
         choice "route" do
           #{option} "selected", condition: item() == 1, action: Echo, params: %{}
           otherwise action: Echo, params: %{}
         end
         output result("route")
         """, "#{option} \"selected\""}

      :fallback_scope ->
        {"""
         choice "route" do
           option "selected", condition: true, action: Echo, params: %{}
           #{fallback} action: Echo, params: item()
         end
         output result("route")
         """, "#{fallback} action:"}

      :option_name ->
        {"""
         choice "route" do
           #{option} "", condition: true, action: Echo, params: %{}
           otherwise action: Echo, params: %{}
         end
         output result("route")
         """, "#{option} \"\""}

      :fallback_parse ->
        {"""
         choice "route" do
           option "selected", condition: true, action: Echo, params: %{}
           #{fallback} action: Echo, params: [Date.utc_today()]
         end
         output result("route")
         """, "#{fallback} action:"}

      :state_parse ->
        {"""
         iterate "loop" do
           #{state} [], initial: [Date.utc_today()]
           action Echo
           params %{}
           repeat 1
         end
         output result("loop")
         """, "#{state} []"}

      :state_schema ->
        {"""
         iterate "loop" do
           #{state} :invalid_schema, initial: %{}
           action Echo
           params %{}
           repeat 1
         end
         output result("loop")
         """, "#{state} :invalid_schema"}
    end
  end

  defp compile_error(declarations, debug_info \\ true) do
    previous = Code.compiler_options()
    module = Module.concat(__MODULE__, "Invalid#{System.unique_integer([:positive])}")

    source = """
    defmodule #{inspect(module)} do
      use Jido.Flow, name: "nested_source", extensions: [#{inspect(__MODULE__.Extension)}]
      alias JidoActionTest.Fixtures.Actions.EchoParamsAction, as: Echo
      flow do
    #{declarations}
      end
    end
    """

    try do
      Code.compiler_options(debug_info: debug_info)

      {assert_raise(CompileError, fn -> Code.compile_string(source, "nested_source.ex") end),
       source}
    after
      Code.compiler_options(previous)
    end
  end
end
