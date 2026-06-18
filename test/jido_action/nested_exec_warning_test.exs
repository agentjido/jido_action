defmodule Jido.Action.NestedExecWarningTest do
  use JidoTest.ActionCase, async: true

  import ExUnit.CaptureIO

  defmodule TargetAction do
    use Jido.Action, name: "nested_exec_warning_target"

    @impl true
    def run(params, _context), do: {:ok, params}
  end

  test "warns when run/2 calls Jido.Exec.run" do
    module = unique_module("QualifiedNestedExecAction")

    warning = compile_action(module, nested_run_body())

    assert warning =~ "nested Jido action execution inside #{inspect(module)}.run/2"
    assert warning =~ "Calling Jido.Exec.run inside an action makes composition opaque"
    assert warning =~ "@jido_allow_nested_exec true"
  end

  test "does not warn when nested execution is explicitly allowed" do
    module = unique_module("AllowedNestedExecAction")

    warning =
      compile_action(
        module,
        """
        @jido_allow_nested_exec true

        #{nested_run_body()}
        """
      )

    refute warning =~ "nested Jido action execution"
  end

  test "does not warn for helper functions outside run/2" do
    module = unique_module("HelperNestedExecAction")

    warning =
      compile_action(
        module,
        """
        def helper(params, context) do
          Jido.Exec.run(#{inspect(__MODULE__.TargetAction)}, params, context)
        end

        @impl true
        def run(params, _context) do
          {:ok, params}
        end
        """
      )

    refute warning =~ "nested Jido action execution"
  end

  defp nested_run_body do
    """
    @impl true
    def run(params, context) do
      Jido.Exec.run(#{inspect(__MODULE__.TargetAction)}, params, context)
    end
    """
  end

  defp compile_action(module, body) do
    name =
      module
      |> Module.split()
      |> List.last()
      |> Macro.underscore()

    capture_io(:stderr, fn ->
      Code.compile_string("""
      defmodule #{inspect(module)} do
        use Jido.Action, name: #{inspect(name)}

      #{body}
      end
      """)
    end)
  end
end
