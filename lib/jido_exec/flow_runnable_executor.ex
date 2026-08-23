defmodule Jido.Exec.FlowRunnableExecutor do
  @moduledoc false

  alias Jido.Action.{Error, Telemetry}
  alias Jido.Exec.Execution
  alias Jido.Flow.{Element, NodeError}
  alias Jido.Flow.Runtime.OrderedTaskRunner
  alias Runic.Workflow
  alias Runic.Workflow.{Runnable, Step}

  @spec execute(Execution.t(), Runnable.t()) :: Runnable.t()
  def execute(%Execution{} = execution, %Runnable{} = runnable) do
    execute(execution, runnable, element_kinds(execution))
  end

  @spec execute_many(Execution.t(), [Runnable.t()]) :: [Runnable.t()]
  def execute_many(%Execution{} = execution, runnables) when is_list(runnables) do
    element_kinds = element_kinds(execution)

    if Keyword.fetch!(execution.options, :async) do
      execute_async(execution, runnables, element_kinds)
    else
      Enum.map(runnables, &execute(execution, &1, element_kinds))
    end
  end

  @spec normalize_error(String.t(), term()) :: Exception.t()
  def normalize_error(_node, %NodeError{error: error}), do: error
  def normalize_error(_node, error) when is_exception(error), do: error

  def normalize_error(node, reason) do
    Error.execution_error("flow node failed", %{node: node, reason: reason})
  end

  defp execute(execution, runnable, element_kinds) do
    span = start_span(execution, runnable, element_kinds)
    executed = Workflow.execute_runnable(runnable)
    finish_span(span, executed)
    executed
  end

  defp execute_async(execution, runnables, element_kinds) do
    spans = Enum.map(runnables, &start_span(execution, &1, element_kinds))
    max_concurrency = Keyword.fetch!(execution.options, :max_concurrency)

    executed =
      OrderedTaskRunner.run(
        runnables,
        max_concurrency,
        &Workflow.execute_runnable/1,
        &fail_exited_runnable/2
      )

    executed
    |> Enum.zip(spans)
    |> Enum.map(fn {runnable, span} ->
      finish_span(span, runnable)
      runnable
    end)
  end

  defp start_span(execution, %Runnable{node: %Step{name: name}}, element_kinds) do
    Telemetry.start([:jido, :flow, :node], %{
      execution_id: execution.id,
      flow: execution.flow_name,
      node: name,
      kind: Map.fetch!(element_kinds, name)
    })
  end

  defp finish_span(span, %Runnable{status: :completed}), do: Telemetry.stop(span)

  defp finish_span(span, %Runnable{node: %Step{name: name}, status: :failed, error: error}) do
    Telemetry.error(span, normalize_error(name, error))
  end

  defp finish_span(span, %Runnable{node: %Step{name: name}, status: status}) do
    Telemetry.error(
      span,
      Error.execution_error("flow node returned an unsupported execution status", %{
        node: name,
        status: status
      })
    )
  end

  defp element_kinds(%Execution{flow: %{nodes: nodes}}) do
    Map.new(nodes, fn element -> {Element.name(element), Element.kind(element)} end)
  end

  defp fail_exited_runnable(runnable, reason) do
    Runnable.fail(
      runnable,
      Error.execution_error("flow node task exited", %{
        node: runnable.node.name,
        reason: reason
      })
    )
  end
end
