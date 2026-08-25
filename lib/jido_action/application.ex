defmodule Jido.Action.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Jido.Exec.Supervisor.start_link()
  end
end
