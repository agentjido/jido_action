defmodule Jido.Action.NestedExecWarningTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  defmodule TargetAction do
    use Jido.Action, name: "nested_exec_warning_target"

    @impl true
    def run(params, _context), do: {:ok, params}
  end

  test "warns when run/2 calls Jido.Exec.run" do
    module = unique_module("QualifiedNestedExecAction")

    warning =
      capture_io(:stderr, fn ->
        Code.compile_string("""
        defmodule #{inspect(module)} do
          use Jido.Action, name: "qualified_nested_exec_action"

          @impl true
          def run(params, context) do
            Jido.Exec.run(#{inspect(__MODULE__.TargetAction)}, params, context)
          end
        end
        """)
      end)

    assert warning =~ "nested Jido action execution inside #{inspect(module)}.run/2"
    assert warning =~ "Calling Jido.Exec.run/4 inside an action makes composition opaque"
    assert warning =~ "@jido_allow_nested_exec true"
  end

  test "warns when run/2 calls an aliased Jido.Exec.run_async" do
    module = unique_module("AliasedNestedExecAction")

    warning =
      capture_io(:stderr, fn ->
        Code.compile_string("""
        defmodule #{inspect(module)} do
          use Jido.Action, name: "aliased_nested_exec_action"

          alias Jido.Exec, as: Runner

          @impl true
          def run(params, context) do
            Runner.run_async(#{inspect(__MODULE__.TargetAction)}, params, context)
            {:ok, params}
          end
        end
        """)
      end)

    assert warning =~ "nested Jido action execution inside #{inspect(module)}.run/2"
    assert warning =~ "Calling Jido.Exec.run_async/4 inside an action makes composition opaque"
  end

  test "does not warn when nested execution is explicitly allowed" do
    module = unique_module("AllowedNestedExecAction")

    warning =
      capture_io(:stderr, fn ->
        Code.compile_string("""
        defmodule #{inspect(module)} do
          use Jido.Action, name: "allowed_nested_exec_action"

          @jido_allow_nested_exec true

          @impl true
          def run(params, context) do
            Jido.Exec.run(#{inspect(__MODULE__.TargetAction)}, params, context)
          end
        end
        """)
      end)

    refute warning =~ "nested Jido action execution"
  end

  test "does not warn for helper functions outside run/2" do
    module = unique_module("HelperNestedExecAction")

    warning =
      capture_io(:stderr, fn ->
        Code.compile_string("""
        defmodule #{inspect(module)} do
          use Jido.Action, name: "helper_nested_exec_action"

          def helper(params, context) do
            Jido.Exec.run(#{inspect(__MODULE__.TargetAction)}, params, context)
          end

          @impl true
          def run(params, _context) do
            {:ok, params}
          end
        end
        """)
      end)

    refute warning =~ "nested Jido action execution"
  end

  defp unique_module(prefix) do
    Module.concat(__MODULE__, :"#{prefix}#{System.unique_integer([:positive])}")
  end
end
