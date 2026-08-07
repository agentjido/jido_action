defmodule Mix.Tasks.JidoAction.Gen.ActionTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  alias Mix.Tasks.JidoAction.Gen.Action

  test "declares the module name as a positional argument" do
    info = Action.info([], nil)

    assert info.positional == [:module_name]
    assert info.required == []
  end

  test "generates one action module and one test module" do
    module_name = GeneratorReview.Actions.Generated
    test_module_name = Module.concat(module_name, Test)

    igniter =
      test_project()
      |> Igniter.compose_task(Action, [inspect(module_name)])

    action_path = Igniter.Project.Module.proper_location(igniter, module_name)
    test_path = Igniter.Project.Module.proper_location(igniter, test_module_name, :test)

    igniter
    |> assert_creates(action_path, fn contents ->
      assert count_module_definitions(contents) == 1
      assert contents =~ "use Jido.Action"
    end)
    |> assert_creates(test_path, fn contents ->
      assert count_module_definitions(contents) == 1
      assert contents =~ "alias #{inspect(module_name)}"
    end)
  end

  defp count_module_definitions(contents) do
    {:ok, ast} = Code.string_to_quoted(contents)

    {_ast, count} =
      Macro.prewalk(ast, 0, fn
        {:defmodule, _, _} = node, count -> {node, count + 1}
        node, count -> {node, count}
      end)

    count
  end
end
