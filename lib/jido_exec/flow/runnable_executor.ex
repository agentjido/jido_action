defmodule Jido.Exec.Flow.RunnableExecutor do
  @moduledoc false

  alias Jido.Exec.Execution
  alias Jido.Exec.Telemetry
  alias Jido.Flow.Error
  alias Runic.Workflow
  alias Runic.Workflow.Runnable

  @doc "Executes one native Runnable and records its node telemetry."
  @spec execute(Execution.t(), Runnable.t()) :: Runnable.t()
  def execute(%Execution{} = execution, %Runnable{} = runnable) do
    execute_with_metadata(runnable, node_metadata(execution, runnable))
  end

  defp execute_with_metadata(runnable, metadata) do
    span = start_span(metadata)
    executed = safely_execute(runnable)
    finish_span(span, executed)
    executed
  end

  @doc "Executes native Runnables in order with the configured concurrency policy."
  @spec execute_many(Execution.t(), [Runnable.t()]) :: [Runnable.t()]
  def execute_many(%Execution{} = execution, runnables) when is_list(runnables) do
    if Keyword.fetch!(execution.options, :max_concurrency) > 1 and length(runnables) > 1 do
      execute_concurrently(execution, runnables)
    else
      runnables
      |> Enum.reduce_while([], fn runnable, completed ->
        executed = execute(execution, runnable)
        completed = [executed | completed]

        if executed.status == :failed, do: {:halt, completed}, else: {:cont, completed}
      end)
      |> Enum.reverse()
    end
  end

  defp execute_concurrently(execution, runnables) do
    logger_metadata = Logger.metadata()
    telemetry_tracker = Telemetry.tracker()
    group_leader = Process.group_leader()
    stopped = :atomics.new(1, [])

    execute = fn {runnable, index, metadata} ->
      Process.group_leader(self(), group_leader)
      Logger.metadata(logger_metadata)
      Telemetry.put_tracker(telemetry_tracker)
      executed = execute_with_metadata(runnable, metadata)
      if executed.status == :failed, do: :atomics.put(stopped, 1, 1)
      {index, executed}
    end

    # Observe exits without waiting for earlier tasks. Stop the lazy input, but
    # drain admitted tasks and restore source order before applying their results.
    runnables
    |> Enum.with_index()
    |> Stream.take_while(fn _runnable -> :atomics.get(stopped, 1) == 0 end)
    # Resolve telemetry in the caller. Workers must not capture the execution.
    |> Stream.map(fn {runnable, index} ->
      {runnable, index, node_metadata(execution, runnable)}
    end)
    |> Task.async_stream(execute,
      max_concurrency: Keyword.fetch!(execution.options, :max_concurrency),
      ordered: false,
      zip_input_on_exit: true,
      timeout: :infinity
    )
    |> Enum.map(fn
      {:ok, indexed_result} ->
        indexed_result

      {:exit, {{runnable, index, _metadata}, reason}} ->
        :atomics.put(stopped, 1, 1)
        {index, fail_exited_runnable(runnable, reason)}
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp safely_execute(runnable) do
    Workflow.execute_runnable(runnable)
  rescue
    error -> Runnable.fail(runnable, error)
  catch
    kind, reason ->
      Runnable.fail(
        runnable,
        Error.execution_error("flow runnable #{kind}", %{
          runnable_id: runnable.id,
          node: runnable_name(runnable),
          reason: reason
        })
      )
  end

  defp start_span(nil), do: nil
  defp start_span(metadata), do: Telemetry.start([:jido, :flow, :node], metadata)

  defp node_metadata(execution, runnable) do
    case authored_component(execution, runnable) do
      {name, kind} ->
        %{
          execution_id: execution.id,
          flow: execution.flow_name,
          node: name,
          kind: kind
        }

      nil ->
        nil
    end
  end

  defp finish_span(nil, _runnable), do: :ok
  defp finish_span(span, %Runnable{status: :completed}), do: Telemetry.stop(span)
  defp finish_span(span, %Runnable{status: :skipped}), do: Telemetry.stop(span)

  defp finish_span(span, %Runnable{status: :failed, error: error}) do
    Telemetry.error(span, normalize_error(error))
  end

  defp finish_span(span, %Runnable{status: status}) do
    Telemetry.error(span, Error.execution_error("unsupported runnable status", %{status: status}))
  end

  defp authored_component(execution, %Runnable{node: %{name: runnable_name}}) do
    Enum.find_value(execution.compiled.component_index, fn {name, index} ->
      if index.output == runnable_name, do: {name, index.kind}
    end)
  end

  defp authored_component(_execution, _runnable), do: nil

  defp fail_exited_runnable(runnable, reason) do
    Runnable.fail(
      runnable,
      Error.execution_error("flow runnable task exited", %{
        runnable_id: runnable.id,
        node: runnable_name(runnable),
        reason: reason
      })
    )
  end

  defp runnable_name(%Runnable{node: %{name: name}}), do: name
  defp runnable_name(%Runnable{node: node}), do: node.__struct__

  defp normalize_error(error) when is_exception(error), do: error

  defp normalize_error(reason),
    do: Error.execution_error("flow runnable failed", %{reason: reason})
end
