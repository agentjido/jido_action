defmodule Jido.Exec.Runner.TaskExecutor do
  @moduledoc false

  @behaviour Runic.Runner.Executor

  @impl Runic.Runner.Executor
  def init(opts) do
    {:ok, %{task_supervisor: Keyword.fetch!(opts, :task_supervisor), tasks: %{}}}
  end

  @impl Runic.Runner.Executor
  def dispatch(work_fn, _opts, state) do
    task = Task.Supervisor.async_nolink(state.task_supervisor, work_fn)
    {task.ref, %{state | tasks: Map.put(state.tasks, task.ref, task.pid)}}
  end

  @impl Runic.Runner.Executor
  def cleanup(state) do
    Enum.each(state.tasks, fn {_reference, pid} ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    :ok
  end
end
