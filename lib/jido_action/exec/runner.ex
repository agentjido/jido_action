defmodule Jido.Exec.Runner do
  @moduledoc """
  Explicit lifecycle wrapper for managed Runic runners.

  `Jido.Exec` is a functional execution facade. When a supervised Runner process
  is wanted, start it through this module and pass its name to `Jido.Exec`
  managed-flow functions.
  """

  @doc """
  Starts a managed Runic runner.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) when is_list(opts) do
    Runic.Runner.start_link(opts)
  end

  @doc false
  def child_spec(opts) when is_list(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end
end
