defmodule Jido.Exec.NoopContextPropagator do
  @moduledoc """
  Default no-op implementation of `Jido.Exec.ContextPropagator`.
  """

  @behaviour Jido.Exec.ContextPropagator

  @impl true
  def capture, do: nil

  @impl true
  def attach(_captured_ctx), do: nil

  @impl true
  def detach(_attached_ctx), do: :ok
end
