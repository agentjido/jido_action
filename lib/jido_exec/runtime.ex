defmodule Jido.Exec.Runtime do
  @moduledoc false

  alias Jido.Action.Error

  @type supervisor_reference :: pid() | atom() | {:via, module(), term()}

  @doc false
  @spec task_supervisor(keyword()) :: {:ok, supervisor_reference()} | {:error, Exception.t()}
  def task_supervisor(opts) do
    with :ok <- validate_options(opts),
         :ok <- reject_duplicate_route(opts) do
      supervisor = Keyword.get(opts, :task_supervisor, Jido.Exec.TaskSupervisor)

      if local_reference?(supervisor) do
        lookup(supervisor)
      else
        invalid_reference(supervisor)
      end
    end
  end

  @doc false
  @spec start_child(supervisor_reference(), (-> term())) :: {:ok, pid()} | {:error, term()}
  def start_child(supervisor, work) do
    case GenServer.whereis(supervisor) do
      pid when is_pid(pid) and node(pid) == node() ->
        Task.Supervisor.start_child(pid, work, restart: :temporary)

      nil ->
        {:error, :noproc}

      _other ->
        {:error, :non_local_supervisor}
    end
  rescue
    error -> {:error, {:error, error}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp validate_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts), do: :ok, else: invalid_options()
  end

  defp validate_options(_opts), do: invalid_options()

  defp invalid_options do
    {:error, Error.validation_error("run options must be a keyword list")}
  end

  defp reject_duplicate_route(opts) do
    if length(Keyword.get_values(opts, :task_supervisor)) > 1 do
      {:error,
       Error.validation_error("pass only one task_supervisor: reference", %{
         option: :task_supervisor,
         reason: :duplicate_option
       })}
    else
      :ok
    end
  end

  defp local_reference?(pid) when is_pid(pid), do: node(pid) == node()
  defp local_reference?(name) when is_atom(name), do: name not in [nil, true, false]

  defp local_reference?({:via, module, _name}) when is_atom(module),
    do: module not in [nil, true, false]

  defp local_reference?(_reference), do: false

  defp lookup(supervisor) do
    case GenServer.whereis(supervisor) do
      nil ->
        not_running(supervisor)

      pid when is_pid(pid) and node(pid) == node() ->
        if Process.alive?(pid), do: {:ok, supervisor}, else: not_running(supervisor)

      _other ->
        invalid_reference(supervisor)
    end
  rescue
    error -> lookup_error(supervisor, error)
  catch
    kind, reason -> lookup_error(supervisor, {kind, reason})
  end

  defp not_running(supervisor) do
    {:error,
     Error.validation_error("Task Supervisor is not running", %{
       option: :task_supervisor,
       task_supervisor: supervisor
     })}
  end

  defp lookup_error(supervisor, reason) do
    {:error,
     Error.validation_error("Task Supervisor lookup failed", %{
       option: :task_supervisor,
       task_supervisor: supervisor,
       reason: reason
     })}
  end

  defp invalid_reference(supervisor) do
    {:error,
     Error.validation_error(
       "task_supervisor must be a local PID, registered name, or {:via, module, name} reference",
       %{option: :task_supervisor, value: supervisor}
     )}
  end
end
