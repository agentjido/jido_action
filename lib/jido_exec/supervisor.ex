defmodule Jido.Exec.Supervisor do
  @moduledoc """
  Starts global Exec services and resolves the Task Supervisor for one run.

  Jido core owns a Task Supervisor for each Jido instance. Pass the instance
  with `jido: MyApp.Jido` to route Action work through
  `MyApp.Jido.TaskSupervisor`. If `:jido` is absent or `nil`, Exec uses its
  global `Jido.Exec.TaskSupervisor`.

  This module does not start instance Task Supervisors. The Jido instance must
  be in the application supervision tree before it is used.
  """

  use Supervisor

  alias Jido.Action.Error

  @type routing_option :: {:jido, atom() | nil}

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Resolves the Task Supervisor name for execution options.

  The function does not test if the process is running. Use
  `task_supervisor/1` at an execution boundary when the process must exist.
  """
  @spec task_supervisor_name([routing_option()]) :: atom()
  def task_supervisor_name(opts) when is_list(opts) do
    case Keyword.get(opts, :jido) do
      nil -> Jido.Exec.TaskSupervisor
      jido when is_atom(jido) -> Module.concat(jido, TaskSupervisor)
      jido -> raise ArgumentError, ":jido must be an atom or nil, got: #{inspect(jido)}"
    end
  end

  @doc """
  Resolves a running Task Supervisor for one execution.

  The function returns a validation error if the selected supervisor is not
  running. It never falls back to the global supervisor for a requested Jido
  instance.
  """
  @spec task_supervisor([routing_option()]) :: {:ok, atom()} | {:error, Exception.t()}
  def task_supervisor(opts) when is_list(opts) do
    supervisor = task_supervisor_name(opts)

    if Process.whereis(supervisor) do
      {:ok, supervisor}
    else
      {:error,
       Error.validation_error("Task Supervisor is not running", %{
         jido: Keyword.get(opts, :jido),
         task_supervisor: supervisor
       })}
    end
  end

  @impl true
  def init(_opts) do
    children = [
      {Task.Supervisor, name: Jido.Exec.TaskSupervisor, max_children: :infinity},
      {Registry, keys: :unique, name: Jido.Exec.ConcurrencyRegistry},
      {DynamicSupervisor, name: Jido.Exec.ConcurrencySupervisor, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
