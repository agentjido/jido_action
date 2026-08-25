defmodule Jido.Exec.OrderedTaskRunner do
  @moduledoc false

  alias Jido.Exec.ConcurrencyLimiter

  @doc false
  @spec run([item], integer(), (item -> result), (item, term() -> result)) :: [result]
        when item: term(), result: term()
  def run(items, max_concurrency, worker_fun, exit_fun)
      when is_list(items) and is_integer(max_concurrency) and is_function(worker_fun, 1) and
             is_function(exit_fun, 2) do
    run(items, max_concurrency, worker_fun, exit_fun, nil)
  end

  @doc false
  @spec run(
          [item],
          integer(),
          (item -> result),
          (item, term() -> result),
          ConcurrencyLimiter.t() | nil
        ) :: [result]
        when item: term(), result: term()
  def run(items, max_concurrency, worker_fun, exit_fun, concurrency_limiter)
      when is_list(items) and is_integer(max_concurrency) and is_function(worker_fun, 1) and
             is_function(exit_fun, 2) do
    requested_slots = min(max(length(items) - 1, 0), max(max_concurrency - 1, 0))
    task_slots = ConcurrencyLimiter.reserve_task_slots(concurrency_limiter, requested_slots)

    try do
      if task_slots == 0 do
        run_inline(items, worker_fun, exit_fun)
      else
        run_concurrently(items, task_slots, worker_fun, exit_fun)
      end
    after
      ConcurrencyLimiter.release_task_slots(concurrency_limiter, task_slots)
    end
  end

  defp run_concurrently(items, task_slots, worker_fun, exit_fun) do
    [inline_lane | async_lanes] = partition_lanes(items, task_slots + 1)

    {worker, monitor, reference} =
      start_async(async_lanes, task_slots, worker_fun, exit_fun)

    inline_results = run_lane(inline_lane, worker_fun, exit_fun)

    (inline_results ++ await_async(worker, monitor, reference))
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp start_async(lanes, task_slots, worker_fun, exit_fun) do
    caller = self()
    logger_metadata = Logger.metadata()
    reference = make_ref()

    {worker, monitor} =
      spawn_monitor(fn ->
        Logger.metadata(logger_metadata)
        worker = self()
        spawn(fn -> terminate_with_caller(caller, worker) end)
        Process.flag(:trap_exit, true)

        task_fun = fn lane ->
          Logger.metadata(logger_metadata)
          run_lane(lane, worker_fun, exit_fun)
        end

        results =
          lanes
          |> Task.async_stream(task_fun,
            max_concurrency: task_slots,
            timeout: :infinity,
            ordered: true
          )
          |> Stream.zip(lanes)
          |> Enum.flat_map(fn
            {{:ok, results}, _lane} ->
              results

            {{:exit, reason}, lane} ->
              Enum.map(lane, fn {index, item} -> {index, exit_fun.(item, reason)} end)
          end)

        send(caller, {reference, self(), results})
      end)

    {worker, monitor, reference}
  end

  defp await_async(worker, monitor, reference) do
    receive do
      {^reference, ^worker, results} ->
        Process.demonitor(monitor, [:flush])
        results

      {:DOWN, ^monitor, :process, ^worker, reason} ->
        exit(reason)
    end
  end

  defp run_inline(items, worker_fun, exit_fun) do
    Enum.map(items, &run_inline_item(&1, worker_fun, exit_fun))
  end

  defp run_inline_item(item, worker_fun, exit_fun) do
    try do
      worker_fun.(item)
    rescue
      exception -> exit_fun.(item, {exception, __STACKTRACE__})
    catch
      :exit, reason -> exit_fun.(item, reason)
      kind, reason -> exit_fun.(item, {{kind, reason}, __STACKTRACE__})
    end
  end

  defp run_lane(lane, worker_fun, exit_fun) do
    Enum.map(lane, fn {index, item} ->
      {index, run_inline_item(item, worker_fun, exit_fun)}
    end)
  end

  defp partition_lanes(items, lane_count) do
    lanes = List.duplicate([], lane_count)

    items
    |> Enum.with_index()
    |> Enum.reduce(lanes, fn {item, index}, lanes ->
      List.update_at(lanes, rem(index, lane_count), &[{index, item} | &1])
    end)
    |> Enum.map(&Enum.reverse/1)
    |> Enum.reject(&(&1 == []))
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
