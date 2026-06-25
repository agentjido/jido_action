defmodule JidoTest.ActionCase do
  @moduledoc """
  Test case helper module providing common test functionality for Jido tests.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import JidoTest.ActionCase
    end
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
end
