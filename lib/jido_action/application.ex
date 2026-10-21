defmodule Jido.Action.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(
      [
        {Task.Supervisor, name: Jido.Exec.TaskSupervisor, max_children: :infinity},
        Jido.Discovery
      ],
      strategy: :one_for_one
    )
  end
end
