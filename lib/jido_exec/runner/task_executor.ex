defmodule Jido.Exec.Runner.TaskExecutor do
  @moduledoc false

  @behaviour Runic.Runner.Executor

  @impl Runic.Runner.Executor
  def init(opts) do
    {:ok, %{task_supervisor: Keyword.fetch!(opts, :task_supervisor), tasks: %{}}}
  end

  @impl Runic.Runner.Executor
  def dispatch(work_fn, _opts, state) do
    worker = self()

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        # The task is not linked to the worker, so stop it if the worker dies.
        watch(worker, self())
        work_fn.()
      end)

    {task.ref, %{state | tasks: Map.put(state.tasks, task.ref, task.pid)}}
  end

  @impl Runic.Runner.Executor
  def release(reference, state), do: %{state | tasks: Map.delete(state.tasks, reference)}

  @impl Runic.Runner.Executor
  def cleanup(state) do
    Enum.each(state.tasks, fn {_reference, pid} ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    :ok
  end

  @doc false
  # Kills `task` and the processes linked to it when `owner` exits. The
  # watcher also exits with the task, because a normal task exit does not stop
  # a linked process.
  @spec watch(pid(), pid()) :: pid()
  def watch(owner, task) do
    spawn_link(fn ->
      owner_monitor = Process.monitor(owner)
      task_monitor = Process.monitor(task)

      receive do
        {:DOWN, ^owner_monitor, :process, ^owner, _reason} -> Process.exit(task, :kill)
        {:DOWN, ^task_monitor, :process, ^task, _reason} -> :ok
      end
    end)
  end
end
