defmodule Jido.Flow.Runtime.OrderedTaskRunner do
  @moduledoc false

  @doc false
  def run(items, max_concurrency, worker_fun, exit_fun)
      when is_list(items) and is_integer(max_concurrency) and is_function(worker_fun, 1) and
             is_function(exit_fun, 2) do
    caller = self()
    reference = make_ref()

    {worker, monitor} =
      spawn_monitor(fn ->
        worker = self()
        spawn(fn -> terminate_with_caller(caller, worker) end)
        Process.flag(:trap_exit, true)

        results =
          items
          |> Task.async_stream(worker_fun,
            max_concurrency: max_concurrency,
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

  defp terminate_with_caller(caller, worker) do
    caller_monitor = Process.monitor(caller)
    worker_monitor = Process.monitor(worker)

    receive do
      {:DOWN, ^caller_monitor, :process, ^caller, _reason} -> Process.exit(worker, :kill)
      {:DOWN, ^worker_monitor, :process, ^worker, _reason} -> :ok
    end
  end
end
