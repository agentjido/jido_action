defmodule Jido.Action.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: Jido.Action.TaskSupervisor, max_children: :infinity},
      {Registry, keys: :unique, name: Jido.Exec.ConcurrencyRegistry},
      {DynamicSupervisor, name: Jido.Exec.ConcurrencySupervisor, strategy: :one_for_one}
    ]

    opts = [strategy: :one_for_one, name: JidoAction.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
