defmodule Jido.Exec.Runtime do
  @moduledoc false

  alias Jido.Exec.{Portable, Validation}
  alias Jido.Instruction

  @reserved [
    :__jido_exec_durable__,
    :__jido_host_capabilities__,
    :__jido_wait_host__,
    :__jido_wait_result__
  ]

  @doc false
  @spec user_context(map()) :: map()
  def user_context(context), do: Map.drop(context, @reserved)

  @doc false
  @spec context(map(), [atom()], boolean()) :: map()
  def context(context, capabilities, durable? \\ false) do
    context
    |> user_context()
    |> Map.put(:__jido_exec_durable__, durable?)
    |> Map.put(:__jido_host_capabilities__, capabilities)
  end

  @doc false
  @spec options(keyword()) :: {:ok, [atom()], keyword()} | {:error, Exception.t()}
  def options(opts) do
    {capabilities, opts} = Keyword.pop(opts, :host_capabilities, [])

    if is_list(capabilities) and not List.improper?(capabilities) and
         Enum.all?(capabilities, &(&1 == :handoff)) do
      {:ok, capabilities, opts}
    else
      {:error,
       Jido.Action.Error.config_error("invalid host capabilities", %{value: capabilities})}
    end
  end

  @doc false
  @spec run(Jido.Exec.task_supervisor(), pid(), (-> term())) :: term()
  def run(task_supervisor, group_leader, work) do
    caller = self()

    task =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        Process.group_leader(self(), group_leader)
        watcher = watch_caller(caller, self())
        result = work.()
        stop_watcher(watcher)
        result
      end)

    case Task.yield(task, :infinity) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, execution_task_error(reason)}
    end
  rescue
    exception ->
      {:error, execution_task_error(exception)}
  catch
    kind, reason ->
      {:error, execution_task_error({kind, reason})}
  end

  # The execution task is not linked to the caller, so a killed Action cannot
  # exit the caller. The linked watcher kills the task, and the processes
  # linked to it, when the caller exits.
  defp watch_caller(caller, task) do
    spawn_link(fn ->
      caller_monitor = Process.monitor(caller)
      task_monitor = Process.monitor(task)

      receive do
        {:DOWN, ^caller_monitor, :process, ^caller, _reason} -> Process.exit(task, :kill)
        {:DOWN, ^task_monitor, :process, ^task, _reason} -> :ok
      end
    end)
  end

  defp stop_watcher(watcher) do
    Process.unlink(watcher)
    Process.exit(watcher, :kill)
  end

  defp execution_task_error(reason) do
    Jido.Action.Error.execution_error("Exec task exited", %{
      phase: :execution_task,
      reason: reason
    })
  end

  @doc false
  @spec flow_input(Jido.Instruction.t()) :: {:ok, Jido.Instruction.t()} | {:error, Exception.t()}
  def flow_input(%Instruction{kind: :action} = instruction), do: {:ok, instruction}

  def flow_input(%Instruction{kind: :flow} = instruction) do
    with {:ok, params} <-
           Validation.input(instruction.target, instruction.params, %{phase: :flow_input}) do
      {:ok, %{instruction | params: params}}
    end
  end

  @doc false
  @spec portable(Jido.Instruction.t()) :: :ok | {:error, Exception.t()}
  def portable(%Instruction{} = instruction) do
    with :ok <- Portable.validate(instruction.params, :params),
         :ok <- Portable.validate(instruction.metadata, :metadata) do
      Portable.validate(instruction.context, :context)
    end
  end
end
