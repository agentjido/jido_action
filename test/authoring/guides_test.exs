defmodule JidoActionTest.Authoring.GuidesTest do
  use ExUnit.Case, async: false

  @moduletag :authoring
  @moduletag capture_log: true

  @examples [
    {"README.md", [2, 3, 4, 6, 7]},
    {"guides/actions.md", [0, 1, 2, 5, 6]},
    {"guides/building-dsls-with-inline-actions.md", [1, 2]},
    {"guides/concepts.md", [0, 1, 2]},
    {"guides/dynamic-flows.md", [1, 2, 4]},
    {"guides/execution.md", [0, 1]},
    {"guides/flow-data.md", :all},
    {"guides/flow-expressions.md", :all},
    {"guides/flow-inspection.md", :all},
    {"guides/flow-modules.md", :all},
    {"guides/flow-storage.md", :all},
    {"guides/flows.md", :all},
    {"guides/inline-actions.md", [0, 6, 8]},
    {"guides/instructions.md", [0, 1, 2, 3, 4, 5, 7, 8, 9]},
    {"guides/managed-execution.md", :all},
    {"guides/schemas-validation.md", [0, 1, 2, 3, 4, 5]}
  ]

  @livebooks Path.wildcard("guides/*.livemd")

  for {filename, selection} <- @examples ++ Enum.map(@livebooks, &{&1, :all}) do
    test "#{filename} examples run against the package source" do
      filename = Path.expand(unquote(filename))
      selection = example_selection(unquote(selection))

      on_exit(fn ->
        for {module, _path} <- :code.all_loaded(),
            module.module_info(:compile)[:source] == String.to_charlist(filename) do
          :code.purge(module)
          :code.delete(module)
        end
      end)

      blocks =
        ~r/(<!-- livebook:\{"force_markdown":true\} -->\s*)?```elixir\n(.*?)\n```/s
        |> Regex.scan(File.read!(filename))
        |> Enum.with_index()
        |> Enum.reject(fn {[_, marker, code], index} ->
          marker != "" or code =~ "Mix.install(" or
            (selection != :all and index not in selection)
        end)
        |> Enum.map(fn {[_, _, code], _index} -> code end)

      blocks =
        if Path.basename(filename) == "execution.md" do
          readme = File.read!("README.md")
          examples = Regex.scan(~r/```elixir\n(.*?)\n```/s, readme, capture: :all_but_first)
          [Enum.at(examples, 2) |> hd(), Enum.at(examples, 4) |> hd() | blocks]
        else
          blocks
        end

      assert blocks != [], "no executable examples selected in #{filename}"

      Enum.reduce(blocks, {[], Code.env_for_eval(file: filename)}, fn code, {bindings, env} ->
        ast = Code.string_to_quoted!(code, file: filename)
        {_result, bindings, env} = Code.eval_quoted_with_env(ast, bindings, env)
        {bindings, env}
      end)
    end
  end

  defp example_selection(selection), do: selection
end
