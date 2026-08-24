defmodule Jido.Flow.Runtime.OrderedTaskRunner do
  @moduledoc false

  alias Jido.Exec.ConcurrencyLimiter

  @doc false
  def run(items, max_concurrency, worker_fun, exit_fun)
      when is_list(items) and is_integer(max_concurrency) and is_function(worker_fun, 1) and
             is_function(exit_fun, 2) do
    run(items, max_concurrency, worker_fun, exit_fun, nil)
  end

  @doc false
  def run(items, max_concurrency, worker_fun, exit_fun, concurrency_limiter)
      when is_list(items) and is_integer(max_concurrency) and is_function(worker_fun, 1) and
             is_function(exit_fun, 2) do
    requested_slots = min(length(items), max_concurrency)
    task_slots = ConcurrencyLimiter.reserve_task_slots(concurrency_limiter, requested_slots)

    try do
      if task_slots == 0 do
        run_inline(items, worker_fun, exit_fun)
      else
        run_async(items, task_slots, worker_fun, exit_fun)
      end
    after
      ConcurrencyLimiter.release_task_slots(concurrency_limiter, task_slots)
    end
  end

  defp run_async(items, task_slots, worker_fun, exit_fun) do
    caller = self()
    logger_metadata = Logger.metadata()
    reference = make_ref()

    {worker, monitor} =
      spawn_monitor(fn ->
        Logger.metadata(logger_metadata)
        worker = self()
        spawn(fn -> terminate_with_caller(caller, worker) end)
        Process.flag(:trap_exit, true)

        task_fun = fn item ->
          Logger.metadata(logger_metadata)
          worker_fun.(item)
        end

        results =
          items
          |> Task.async_stream(task_fun,
            max_concurrency: task_slots,
            timeout: :infinity,
            ordered: true
          )
          |> Stream.zip(items)
          |> Enum.map(fn
            {{:ok, result}, _item} -> result
            {{:exit, reason}, item} -> exit_fun.(item, reason)
          end)

        send(caller, {reference, self(), results})
      end)

    receive do
      {^reference, ^worker, results} ->
        Process.demonitor(monitor, [:flush])
        results

      {:DOWN, ^monitor, :process, ^worker, reason} ->
        exit(reason)
    end
  end

  defp run_inline(items, worker_fun, exit_fun) do
    Enum.map(items, fn item ->
      try do
        worker_fun.(item)
      rescue
        exception -> exit_fun.(item, {exception, __STACKTRACE__})
      catch
        :exit, reason -> exit_fun.(item, reason)
        kind, reason -> exit_fun.(item, {{kind, reason}, __STACKTRACE__})
      end
    end)
  end

  defp terminate_with_caller(caller, worker) do
    caller_monitor = Process.monitor(caller)
    worker_monitor = Process.monitor(worker)

    receive do
      {:DOWN, ^caller_monitor, :process, ^caller, _reason} -> Process.exit(worker, :kill)
      {:DOWN, ^worker_monitor, :process, ^worker, _reason} -> :ok
    end
  end
end
