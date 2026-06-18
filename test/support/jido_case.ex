defmodule JidoTest.ActionCase do
  @moduledoc """
  Test case helper module providing common test functionality for Jido tests.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # Import test helpers

      import JidoTest.ActionCase
      import JidoTest.Helpers.Assertions
    end
  end

  setup _tags do
    # Setup any test state or fixtures needed
    :ok
  end

  @doc """
  Suppresses Logger output from the current test process while executing `fun`.

  Use this around paths that intentionally exercise expected failures. Prefer
  explicit assertions on returned errors over assertions on log text.
  """
  def silence_logger(fun) when is_function(fun, 0) do
    Logger.put_process_level(self(), :none)

    try do
      fun.()
    after
      Logger.delete_process_level(self())
    end
  end

  @doc """
  Creates a unique module name under the calling test module.
  """
  defmacro unique_module(prefix) do
    namespace = __CALLER__.module

    quote bind_quoted: [namespace: namespace, prefix: prefix] do
      Module.concat(namespace, :"#{prefix}#{System.unique_integer([:positive])}")
    end
  end

  @doc """
  Creates a runtime module and asserts that compilation succeeded.
  """
  def create_module(module, quoted) do
    assert {:module, ^module, _bytecode, _term} =
             Module.create(module, quoted, Macro.Env.location(__ENV__))
  end

  @doc """
  Runs an action through the direct action contract used by focused action tests.
  """
  def run_action(action, params, context \\ %{}) do
    with {:ok, params} <- action.validate_params(params),
         {:ok, result} <- action.run(params, context) do
      action.validate_output(result)
    end
  end

  @doc """
  Stop the given process with a non-normal exit reason.
  Can accept either a PID or registered name.
  """
  def shutdown_test_process(pid, reason \\ :shutdown)

  def shutdown_test_process(pid, reason) when is_pid(pid) do
    Process.unlink(pid)
    Process.exit(pid, reason)

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, _, _, _}, 5_000
  end

  def shutdown_test_process(name, reason) when is_atom(name) do
    case Process.whereis(name) do
      nil -> :ok
      pid -> shutdown_test_process(pid, reason)
    end
  end
end
