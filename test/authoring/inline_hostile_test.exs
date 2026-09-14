defmodule JidoActionTest.Authoring.InlineHostileTest do
  use ExUnit.Case, async: false
  @moduletag :authoring

  alias Jido.Exec

  test "invalid bindings and duplicate inline names point to the source declaration" do
    cases = [
      {"""
       step "bad", [value <- input(:value), value <- context(:value)] do
         {:ok, %{value: value}}
       end
       output result("bad")
       """, ~r/duplicate inline Step binding/, "step \"bad\""},
      {"""
       step "same", [] do
         {:ok, %{value: 1}}
       end
       step "same", [] do
         {:ok, %{value: 2}}
       end
       output result("same")
       """, ~r/duplicate Step name/, "step \"same\""}
    ]

    for {{body, message, marker}, index} <- Enum.with_index(cases) do
      source = flow_source("BadInline#{index}", body)
      file = "authoring_bad_inline_#{index}.ex"
      error = assert_raise CompileError, message, fn -> Code.compile_string(source, file) end
      assert error.file == file
      assert is_integer(error.line) and error.line > 0
      assert source |> String.split("\n") |> Enum.at(error.line - 1) |> String.contains?(marker)
    end
  end

  test "an unavailable inline helper reports the body source line" do
    source =
      flow_source(
        "MissingHelper",
        """
        step "bad", [] do
          missing_inline_helper()
        end
        output result("bad")
        """
      )

    {_result, diagnostics} =
      Code.with_diagnostics(fn ->
        assert_raise CompileError, fn ->
          Code.compile_string(source, "authoring_inline_missing_helper.ex")
        end
      end)

    assert Enum.any?(diagnostics, fn diagnostic ->
             diagnostic.severity == :error and
               diagnostic.message =~ "undefined function missing_inline_helper/0" and
               Path.basename(diagnostic.file) == "authoring_inline_missing_helper.ex" and
               source
               |> String.split("\n")
               |> Enum.at(diagnostic_line(diagnostic) - 1)
               |> String.contains?("missing_inline_helper()")
           end)
  end

  test "recompiled inline code changes behavior without changing stored Flow data" do
    suffix = System.unique_integer([:positive])
    module = "JidoActionTest.Authoring.InlineRecompiled#{suffix}"
    file = "authoring_inline_recompiled_#{suffix}.ex"

    Code.compile_string(recompiled_source(module, 1), file)
    owner = Module.concat([module])
    before = owner.flow()
    assert Exec.run(before, %{value: 3}) == {:ok, %{value: 4}}

    {_modules, diagnostics} =
      Code.with_diagnostics(fn -> Code.compile_string(recompiled_source(module, 2), file) end)

    assert Enum.all?(diagnostics, &(&1.severity == :warning))
    assert owner.flow() == before
    assert Exec.run(before, %{value: 3}) == {:ok, %{value: 5}}
  end

  defp flow_source(suffix, body) do
    """
    defmodule JidoActionTest.Authoring.#{suffix} do
      use Jido.Flow, name: "authoring_#{suffix}"
      flow do
        #{body}
      end
    end
    """
  end

  defp recompiled_source(module, addition) do
    """
    defmodule #{module} do
      use Jido.Flow, name: "authoring_recompiled_inline"
      flow do
        step "calc", value <- input(:value) do
          {:ok, %{value: value + #{addition}}}
        end
        output result("calc")
      end
    end
    """
  end

  defp diagnostic_line(%{position: {line, _column}}), do: line
  defp diagnostic_line(%{position: line}), do: line
end
