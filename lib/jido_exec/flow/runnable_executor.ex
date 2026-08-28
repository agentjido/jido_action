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
    span = start_span(execution, runnable)
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
      Enum.map(runnables, &execute(execution, &1))
    end
  end

  defp execute_concurrently(execution, runnables) do
    logger_metadata = Logger.metadata()
    telemetry_tracker = Telemetry.tracker()
    group_leader = Process.group_leader()

    execute = fn runnable ->
      Process.group_leader(self(), group_leader)
      Logger.metadata(logger_metadata)
      Telemetry.put_tracker(telemetry_tracker)
      execute(execution, runnable)
    end

    runnables
    |> Task.async_stream(execute,
      max_concurrency: Keyword.fetch!(execution.options, :max_concurrency),
      ordered: true,
      timeout: :infinity
    )
    |> Enum.zip(runnables)
    |> Enum.map(fn
      {{:ok, executed}, _runnable} -> executed
      {{:exit, reason}, runnable} -> fail_exited_runnable(runnable, reason)
    end)
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

  defp start_span(execution, runnable) do
    case authored_component(execution, runnable) do
      {name, kind} ->
        Telemetry.start([:jido, :flow, :node], %{
          execution_id: execution.id,
          flow: execution.flow_name,
          node: name,
          kind: kind
        })

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
