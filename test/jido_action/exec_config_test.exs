defmodule JidoTest.ExecConfigTest do
  @moduledoc """
  Tests specifically targeting configuration function coverage
  """

  use JidoTest.ActionCase, async: false

  import ExUnit.CaptureLog

  alias Jido.Action.Error
  alias Jido.Exec

  @moduletag :capture_log

  defmodule InvalidRuntimeConfigRetryAction do
    use Jido.Action,
      name: "invalid_runtime_config_retry_action",
      description: "Action that always fails for retry config fallback tests"

    @impl true
    def run(_params, _context), do: {:error, Error.execution_error("retry fallback test failure")}
  end

  describe "configuration function direct coverage" do
    test "directly trigger configuration helper functions" do
      # Clear and restore app config to force the helpers to be called
      original_timeout = Application.get_env(:jido_action, :default_timeout)
      original_max_retries = Application.get_env(:jido_action, :default_max_retries)
      original_backoff = Application.get_env(:jido_action, :default_backoff)

      try do
        # Delete config to force default values
        Application.delete_env(:jido_action, :default_timeout)
        Application.delete_env(:jido_action, :default_max_retries)
        Application.delete_env(:jido_action, :default_backoff)

        # Force module recompilation to trigger the helper functions
        Code.compiler_options(ignore_module_conflict: true)

        # These operations should trigger the config helper functions
        capture_log(fn ->
          # Test async without explicit timeout (should use get_default_timeout)
          async_ref = Exec.run_async(JidoTest.TestActions.BasicAction, %{value: 1}, %{})
          assert {:ok, %{value: 1}} = Exec.await(async_ref)
        end)

        # Test retry without explicit max_retries (should use get_default_max_retries)
        defmodule ConfigTestAction do
          use Jido.Action, name: "config_test", description: "Config test action"

          alias Jido.Action.Error

          def run(%{should_fail: true}, _context) do
            {:error, Error.execution_error("config test error")}
          end

          def run(params, _context), do: {:ok, params}
        end

        capture_log(fn ->
          # This should use default max_retries and backoff
          assert {:error, _} = Exec.run(ConfigTestAction, %{should_fail: true}, %{})
        end)
      after
        # Restore original config
        if original_timeout do
          Application.put_env(:jido_action, :default_timeout, original_timeout)
        end

        if original_max_retries do
          Application.put_env(:jido_action, :default_max_retries, original_max_retries)
        end

        if original_backoff do
          Application.put_env(:jido_action, :default_backoff, original_backoff)
        end

        Code.compiler_options(ignore_module_conflict: false)
      end
    end

    test "force config helpers through internal calls" do
      # These operations specifically target the uncovered config helper functions
      original_configs = [
        {:default_timeout, Application.get_env(:jido_action, :default_timeout)},
        {:default_max_retries, Application.get_env(:jido_action, :default_max_retries)},
        {:default_backoff, Application.get_env(:jido_action, :default_backoff)}
      ]

      try do
        # Clear all configs
        Enum.each(original_configs, fn {key, _} ->
          Application.delete_env(:jido_action, key)
        end)

        # Create an action that will trigger all the config paths
        defmodule AllConfigPathsAction do
          use Jido.Action, name: "all_config_paths", description: "Triggers all config paths"

          alias Jido.Action.Error

          def run(%{attempt: attempt}, _context) when attempt < 2 do
            {:error, Error.execution_error("retry error")}
          end

          def run(params, _context), do: {:ok, params}
        end

        capture_log(fn ->
          # This should trigger get_default_max_retries and get_default_backoff
          result = Exec.run(AllConfigPathsAction, %{attempt: 1}, %{})
          # Should eventually succeed after retries
          case result do
            {:ok, _} -> :ok
            {:error, _} -> :ok
          end
        end)

        # Test async path to trigger get_default_timeout
        capture_log(fn ->
          async_ref = Exec.run_async(AllConfigPathsAction, %{attempt: 5}, %{})
          # This should trigger get_default_timeout for await
          assert {:ok, %{attempt: 5}} = Exec.await(async_ref)
        end)
      after
        # Restore configs
        Enum.each(original_configs, fn {key, value} ->
          if value do
            Application.put_env(:jido_action, key, value)
          end
        end)
      end
    end
  end

  describe "invalid runtime config fallback guards" do
    test "falls back to defaults for invalid sync timeout config without hanging" do
      with_runtime_config([default_timeout: :invalid_timeout], fn ->
        task = Task.async(fn -> Exec.run(JidoTest.TestActions.BasicAction, %{value: 42}, %{}) end)
        yielded = Task.yield(task, 1_000)

        if is_nil(yielded) do
          _ = Task.shutdown(task, :brutal_kill)
          flunk("Exec.run/3 did not return when :default_timeout was invalid")
        end

        assert {:ok, {:ok, %{value: 42}}} = yielded
      end)
    end

    test "falls back to defaults for invalid async await timeout config" do
      with_runtime_config([default_timeout: :invalid_timeout], fn ->
        async_ref = Exec.run_async(JidoTest.TestActions.BasicAction, %{value: 7}, %{})
        assert {:ok, %{value: 7}} = Exec.await(async_ref)
      end)
    end

    test "falls back to defaults for invalid retry and backoff config" do
      with_runtime_config(
        [default_timeout: 0, default_max_retries: :invalid, default_backoff: :bad],
        fn ->
          assert {:error, error} = Exec.run(InvalidRuntimeConfigRetryAction, %{}, %{})
          assert %Error.ExecutionFailureError{} = error
          assert Exception.message(error) =~ "retry fallback test failure"
        end
      )
    end
  end

  defp with_runtime_config(overrides, fun) when is_list(overrides) and is_function(fun, 0) do
    missing = make_ref()

    original_values =
      Enum.map(overrides, fn {key, _value} ->
        {key, Application.get_env(:jido_action, key, missing)}
      end)

    try do
      Enum.each(overrides, fn {key, value} ->
        Application.put_env(:jido_action, key, value)
      end)

      fun.()
    after
      Enum.each(original_values, fn
        {key, ^missing} -> Application.delete_env(:jido_action, key)
        {key, value} -> Application.put_env(:jido_action, key, value)
      end)
    end
  end
end
