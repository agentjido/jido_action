defmodule Jido.Action.InlineDocsTest do
  use ExUnit.Case, async: false

  @guide Path.expand("../../guides/inline-actions.md", __DIR__)
  @prefixes ["Elixir.InlineHostGuide.", "Elixir.InlineFlowGuide."]

  setup do
    assert owned_modules() == [], "documentation example modules must not already be loaded"

    on_exit(fn ->
      for module <- owned_modules() do
        :code.purge(module)
        :code.delete(module)
      end
    end)
  end

  test "the public non-Flow host runs bound and callback declarations with schemas and context" do
    bindings = eval_section("Build A Non-Flow Host")
    assert Keyword.fetch!(bindings, :bound_result) == {:ok, %{message: "Hello, ADA!"}}
    assert Keyword.fetch!(bindings, :callback_result) == {:ok, %{message: "Hi, GRACE!"}}

    for owner <- [InlineHostGuide.Bound, InlineHostGuide.Callback] do
      target = owner.action_target("greet")
      assert target.name() == "public_greeting"
      assert target.description() == "Create a greeting"
      assert {:ok, %{name: "Ada", suffix: "!"}} = target.validate_params(%{name: "Ada"})
      assert target.output_schema().fields == Zoi.object(%{message: Zoi.string()}).fields
      refute Keyword.has_key?(target.schema().fields, :ctx)

      assert {:error, %Jido.Action.Error.InvalidInputError{}} =
               Jido.Exec.run(target, %{name: 42}, %{prefix: "Hi"})

      assert {:ok, %{message: "Reuse, ADA?"}} =
               Jido.Exec.run(target, %{name: "Ada", suffix: "?"}, %{prefix: "Reuse"})
    end

    assert apply(InlineHostGuide.Callback, :action_source, ["greet"]) == nil

    assert %{__struct__: InlineHostGuide.Field, key: :person} =
             apply(InlineHostGuide.Bound, :action_source, ["greet"])

    assert {:error, {:missing_field, :person}} =
             apply(InlineHostGuide.DSL, :run, [InlineHostGuide.Bound, "greet", %{}])
  end

  test "the documented host rejects unsupported sources and invalid Action schemas" do
    eval_section("Build A Non-Flow Host")

    for source <- ["field(:unknown)", "false and field(:unknown)", "System.unique_integer()"] do
      error =
        assert_raise CompileError, fn ->
          Code.compile_string("""
          defmodule InlineHostGuide.Invalid do
            use InlineHostGuide.DSL, mode: :bound, fields: [:person]
            action "bad", value <- #{source} do
              {:ok, %{value: value}}
            end
          end
          """)
        end

      assert error.description =~ "invalid host source"

      assert_raise ArgumentError, fn ->
        Jido.Action.Inline.target!(InlineHostGuide.Invalid,
          host: InlineHostGuide.DSL,
          declaration: "bad",
          role: :action
        )
      end
    end

    assert_raise CompileError, ~r/schema|configuration/, fn ->
      Code.compile_string("""
      defmodule InlineHostGuide.InvalidSchema do
        use InlineHostGuide.DSL, mode: :callback
        action "bad", params, schema: Zoi.integer() do
          {:ok, params}
        end
      end
      """)
    end

    assert_raise ArgumentError, fn ->
      Jido.Action.Inline.target!(InlineHostGuide.InvalidSchema,
        host: InlineHostGuide.DSL,
        declaration: "bad",
        role: :action
      )
    end
  end

  test "Flow examples run every mapped role, callback continuation, and target-only reuse" do
    bindings = eval_section("Use Inline Actions In Flow")

    assert Keyword.fetch!(bindings, :mapped_result) ==
             {:ok, %{total: 12, route: %{label: :positive}, count: 2}}

    assert Keyword.fetch!(bindings, :dispatch_result) ==
             {:ok, %{value: 4, prefix: "next", complete: true}}

    assert {:ok, %{total: 0, route: %{label: :empty}, count: 2}} =
             Jido.Exec.run(InlineFlowGuide.Mapped, %{values: []})

    for path <- [
          [step: "seed", role: :action],
          [map: "doubled", role: :action],
          [reduce: "total", role: :action],
          [choice: "route", option: "positive", role: :action],
          [choice: "route", fallback: :otherwise, role: :action],
          [iterate: "counter", role: :action]
        ] do
      target = Jido.Action.Inline.target!(InlineFlowGuide.Mapped, [host: Jido.Flow] ++ path)
      assert target.__jido_executable__().kind == :action
    end

    target = Keyword.fetch!(bindings, :double)
    assert {:ok, %{value: 10}} = Jido.Exec.run(target, %{value: 5})
    assert_raise ArgumentError, fn -> apply(InlineFlowGuide.Mapped, :step_action, ["doubled"]) end
  end

  test "the guide uses public host APIs and separates unreleased examples from beta.5" do
    source = File.read!(@guide)
    [_, host] = String.split(source, "## Build A Non-Flow Host\n", parts: 2)
    host = host |> String.split(~r/^## /m, parts: 2) |> hd()

    refute host =~ "Jido.Flow"
    refute host =~ "Spark"
    refute source =~ "Jido.Action.Inline.Compiler"
    refute source =~ "Jido.Action.Inline.Owner"
    refute source =~ "Mix.install"
    assert source =~ "unreleased"
    assert source =~ "3.0.0-beta.5"

    for api <- [
          "parse_bound!",
          "parse_callback!",
          "compile!",
          "target!",
          "leaf_parser:",
          "validate_leaf:",
          "resolve:"
        ] do
      assert host =~ api
    end
  end

  test "guide cells keep nested blocks and schema options stable under formatting" do
    {config, _bindings} = Code.eval_file(Path.expand("../../.formatter.exs", __DIR__))
    # The sample host adds a declaration name, so it also owns action/4 syntax.
    locals = config[:export][:locals_without_parens] ++ [action: 4]

    for [_, code] <- Regex.scan(~r/^```elixir\n(.*?)^```/ms, File.read!(@guide)) do
      formatted =
        code |> Code.format_string!(locals_without_parens: locals) |> IO.iodata_to_binary()

      assert String.trim_trailing(code) == formatted
    end
  end

  defp eval_section(heading) do
    source = File.read!(@guide)
    [_, section] = String.split(source, "## " <> heading <> "\n", parts: 2)
    section = section |> String.split(~r/^## /m, parts: 2) |> hd()
    cells = for [_, code] <- Regex.scan(~r/^```elixir\n(.*?)^```/ms, section), do: code
    assert cells != []

    {{_value, bindings}, diagnostics} =
      Code.with_diagnostics(fn ->
        Code.eval_string(Enum.join(cells, "\n\n"), [], file: @guide)
      end)

    assert diagnostics == []
    bindings
  end

  defp owned_modules do
    for {module, _path} <- :code.all_loaded(), owned_module?(module), do: module
  end

  defp owned_module?(module) do
    cond do
      String.starts_with?(Atom.to_string(module), @prefixes) ->
        true

      function_exported?(module, :__jido_inline_action__, 0) ->
        {owner, _path} = module.__jido_inline_action__()
        String.starts_with?(Atom.to_string(owner), @prefixes)

      function_exported?(module, :__jido_inline_step__, 0) ->
        {owner, _step} = module.__jido_inline_step__()
        String.starts_with?(Atom.to_string(owner), @prefixes)

      true ->
        false
    end
  end
end
