defmodule Jido.Exec do
  @moduledoc """
  Public v4 execution boundary.

  The first Flow foundation establishes this module as the single execution
  entry point. Concrete action, instruction, and Flow execution behavior is
  layered in later implementation units.
  """

  alias Jido.Action.Error

  @doc """
  Runs an executable Jido artifact.
  """
  @spec run(term(), map(), map()) :: {:ok, term()} | {:error, Exception.t()}
  def run(_executable, _input \\ %{}, _context \\ %{}) do
    {:error, Error.config_error("Jido.Exec.run/3 is not implemented for this executable yet")}
  end
end
