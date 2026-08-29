defmodule Jido.Exec.Runtime do
  @moduledoc false

  alias Jido.Action.Error

  @type routing_option :: {:jido, atom() | nil}

  @doc false
  @spec task_supervisor_name([routing_option()]) :: atom()
  def task_supervisor_name(opts) when is_list(opts) do
    Jido.Exec.task_supervisor_name(Keyword.get(opts, :jido))
  rescue
    ArgumentError ->
      jido = Keyword.get(opts, :jido)
      raise ArgumentError, ":jido must be an atom or nil, got: #{inspect(jido)}"
  end

  @doc false
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
end
