defmodule Jido.Action.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: Jido.Exec.TaskSupervisor, max_children: :infinity}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
