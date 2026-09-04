defmodule Jido.Flow.DSL.InlineStepDocsTest do
  use ExUnit.Case, async: false

  @root Path.expand("../../..", __DIR__)
  @owners [
    "Elixir.FirstFlow.",
    "Elixir.FlowSteps.",
    "Elixir.FlowLanguage.",
    "Elixir.MyApp.Flows.SimpleGreeting",
    "Elixir.MyApp.Flows.Greeting",
    "Elixir.ActionGuide.",
    "Elixir.ExprGuide."
  ]

  setup do
    assert owned_modules() == [], "documentation example modules must not already be loaded"

    on_exit(fn ->
      for module <- owned_modules() do
        :code.purge(module)
        :code.delete(module)
      end
    end)
  end

  test "the first-Flow guide runs, extracts an Action, and agrees with Builder and real JSON" do
    first = eval_cells("guides/build-your-first-flow.livemd", install: true)
    flow = Keyword.fetch!(first, :flow)

    assert {:ok, %{message: "Hello, Ada!"}} = Jido.Exec.run(flow, %{name: " Ada "})
    assert length(flow.components) == 2
    assert Enum.all?(flow.components, &match?(%Jido.Flow.Step{}, &1))

    for step <- flow.components do
      assert step.action.__jido_inline_step__() == {FirstFlow.Greeting, step.name}
    end

    assert flow.schema != []
    assert flow.output_schema != []

    built = eval_cells("guides/flow-builder.md", section: "Reuse An Inline Step")
    built_flow = Keyword.fetch!(built, :built_flow)
    assert built_flow == flow

    stored = eval_cells("guides/flow-storage.md", section: "Store A Compiled Inline Step")
    restored = Keyword.fetch!(stored, :restored)
    document = Keyword.fetch!(stored, :document)
    json = Keyword.fetch!(stored, :json)

    assert restored == built_flow
    assert is_binary(json)
    assert JSON.decode!(json) == document
    assert document["version"] == 1

    assert Enum.map(document["components"], & &1["action"]) == [
             "actions/greeting/normalize/v1",
             "actions/greeting/greet/v1"
           ]

    for step <- document["components"] do
      assert Enum.sort(Map.keys(step)) == ["action", "after", "kind", "meta", "name", "params"]
    end

    assert {:ok, %{message: "Hello, Ada!"}} = Jido.Exec.run(restored, %{name: " Ada "})
  end

  test "the Steps Livebook runs every binding form and the existing Action forms" do
    bindings = eval_cells("guides/flow-steps.livemd", install: true)

    assert Keyword.fetch!(bindings, :output) == %{
             first: %{value: 7},
             second: %{value: 7, tag: :complete}
           }

    flow = apply(FlowSteps.Inline, :flow, [])

    assert Enum.map(flow.components, & &1.name) == [
             "ready",
             "normalize",
             "greet",
             "label",
             "profile"
           ]

    for step <- flow.components do
      assert step.action.__jido_inline_step__() == {FlowSteps.Inline, step.name}
    end

    [ready, normalize, greet, label, profile] = flow.components
    assert ready.params == %{}
    assert normalize.params == %{name: Jido.Flow.Ref.input(:name)}
    assert Enum.sort(Map.keys(greet.params)) == [:name, :prefix]
    assert Enum.sort(Map.keys(label.params)) == [:city, :ctx, :name]
    assert label.params.ctx == Jido.Flow.Ref.context()
    assert profile.params == Jido.Flow.Ref.input(:profile)
  end

  test "the DSL Livebook combines an inline Step with the other component forms" do
    bindings = eval_cells("guides/flow-language.livemd", install: true)

    assert Keyword.fetch!(bindings, :result) == %{
             route: %{route: :fast, value: 10},
             values: [1, 2, 3],
             counter: %{count: 2}
           }
  end

  test "the README, Action guide, and Flow module example compile from their source" do
    eval_cells("README.md", section: "Use Inline Steps For Small Operations", level: 3)
    eval_cells("guides/actions.md", section: "Use An Inline Step For Small Local Work")
    eval_cells("guides/flow-modules.md", section: "Define A Module")
    eval_cells("guides/flow-modules.md", section: "Generated API")

    for owner <- [MyApp.Flows.SimpleGreeting, ActionGuide.Greeting, MyApp.Flows.Greeting] do
      assert {:ok, %{message: "Hello, Ada!"}} = Jido.Exec.run(owner, %{name: "Ada"})
    end
  end

  test "the expression guide runs Flow, Builder, JSON, and an independent host DSL" do
    bindings = eval_cells("guides/flow-expressions.md", [])
    assert Keyword.fetch!(bindings, :built) == Keyword.fetch!(bindings, :restored)
    assert Keyword.fetch!(bindings, :document)["version"] == 2
  end

  defp eval_cells(relative_path, opts) do
    path = Path.join(@root, relative_path)
    source = path |> File.read!() |> select_section(opts)

    cells =
      for [block, code] <- Regex.scan(~r/^```elixir\n(.*?)^```/ms, source, return: :index),
          not markdown_cell?(source, block) do
        {start, length} = code
        binary_part(source, start, length)
      end

    assert cells != [], "no Elixir cells found in #{relative_path}"
    {install, cells} = Enum.split_with(cells, &String.starts_with?(&1, "Mix.install("))

    if opts[:install] do
      assert [install_cell] = install

      assert String.trim(install_cell) ==
               ~s|Mix.install([{:jido_action, "~> #{Mix.Project.config()[:version]}"}])|
    else
      assert install == []
    end

    # Mix already owns this test application's dependencies. Execute every
    # other cell from the guide, with one shared binding scope per guide.
    {{_value, bindings}, diagnostics} =
      Code.with_diagnostics(fn ->
        Code.eval_string(Enum.join(cells, "\n\n"), [], file: path)
      end)

    assert diagnostics == []
    bindings
  end

  defp select_section(source, opts) do
    case opts[:section] do
      nil ->
        source

      heading ->
        marker = String.duplicate("#", Keyword.get(opts, :level, 2)) <> " " <> heading <> "\n"
        [_, section] = String.split(source, marker, parts: 2)
        section |> String.split(~r/^\#{1,3} /m, parts: 2) |> hd()
    end
  end

  defp markdown_cell?(source, {start, _length}) do
    source
    |> binary_part(0, start)
    |> String.trim_trailing()
    |> String.ends_with?(~s(<!-- livebook:{"force_markdown":true} -->))
  end

  defp owned_modules do
    for {module, _path} <- :code.all_loaded(), owned_module?(module), do: module
  end

  defp owned_module?(module) do
    name = Atom.to_string(module)

    cond do
      String.starts_with?(name, @owners) ->
        true

      String.starts_with?(name, "Elixir.Jido.Flow.Generated.InlineStep.") ->
        {owner, _step} = module.__jido_inline_step__()
        String.starts_with?(Atom.to_string(owner), @owners)

      true ->
        false
    end
  end
end
