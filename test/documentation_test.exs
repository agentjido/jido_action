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
end
