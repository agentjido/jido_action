defmodule Jido.Exec.FlowEngine do
  @moduledoc false

  alias Jido.Action.Error
  alias Jido.Action.Telemetry
  alias Jido.Exec.{Execution, NodeResult}
  alias Jido.Flow
  alias Jido.Flow.{Compiler, Element, NodeError}
  alias Jido.Flow.Runtime.OrderedTaskRunner
  alias Runic.Workflow
  alias Runic.Workflow.{Fact, Runnable, Step}

  @spec start(Flow.t(), map(), map(), keyword(), function(), function(), String.t(), map()) ::
          {:ok, Execution.t()} | {:error, Exception.t()}
  def start(
        %Flow{} = flow,
        input,
        context,
        options,
        finalizer,
        target_runner,
        execution_id,
        lifecycle
      )
      when is_map(input) and is_map(context) and is_list(options) and
             is_function(finalizer, 1) and is_function(target_runner, 4) and
             is_binary(execution_id) and is_map(lifecycle) do
    with {:ok, workflow, ordered_elements} <-
           Compiler.runtime_workflow_validated(
             flow,
             input,
             context,
             options,
             target_runner,
             execution_id
           ) do
      ordered_nodes = Enum.map(ordered_elements, &Element.name/1)

      execution = %Execution{
        id: execution_id,
        flow_name: flow.name,
        status: :running,
        revision: 0,
        flow: flow,
        input: input,
        context: context,
        options: options,
        workflow: Workflow.plan_eagerly(workflow, input),
        ordered_nodes: ordered_nodes,
        node_names: MapSet.new(ordered_nodes),
        node_positions: ordered_nodes |> Enum.with_index() |> Map.new(),
        ready: %{},
        ready_nodes: [],
        node_results: %{},
        node_errors: %{},
        engine_error: nil,
        finalizer: finalizer,
        final_result: nil,
        lifecycle: lifecycle
      }

      settle(execution)
    end
  end

  @spec ready(Execution.t()) :: [String.t()]
  def ready(%Execution{ready_nodes: ready_nodes}), do: ready_nodes

  @spec status(Execution.t()) :: :running | :succeeded | :failed
  def status(%Execution{status: status}), do: status

  @spec result(Execution.t()) :: {:ok, term()} | {:error, Exception.t()}
  def result(%Execution{status: :running} = execution) do
    {:error,
     Error.validation_error("flow execution is not complete", %{
       flow: execution.flow_name,
       status: :running,
       ready: ready(execution)
     })}
  end

  def result(%Execution{final_result: result}) when not is_nil(result), do: result

  @spec step(Execution.t()) ::
          {:ok, NodeResult.t(), Execution.t()} | {:error, Exception.t()}
  def step(%Execution{} = execution) do
    case ready(execution) do
      [node | _rest] -> step(execution, node)
      [] -> execution_not_running(execution)
    end
  end

  @spec step(Execution.t(), String.t()) ::
          {:ok, NodeResult.t(), Execution.t()} | {:error, Exception.t()}
  def step(%Execution{status: :running} = execution, node) when is_binary(node) do
    case Map.fetch(execution.ready, node) do
      {:ok, runnable} ->
        {node_result, execution} =
          execution
          |> apply_public_runnable(node, execute_runnable(execution, runnable))

        with {:ok, execution} <- settle(execution) do
          {:ok, node_result, execution}
        end

      :error ->
        {:error,
         Error.validation_error("flow node is not ready", %{
           flow: execution.flow_name,
           node: node,
           ready: ready(execution)
         })}
    end
  end

  def step(%Execution{status: :running}, node) do
    {:error,
     Error.validation_error("flow node name must be a string", %{
       node: node
     })}
  end

  def step(%Execution{} = execution, _node), do: execution_not_running(execution)

  @spec wave(Execution.t()) ::
          {:ok, [NodeResult.t()], Execution.t()} | {:error, Exception.t()}
  def wave(%Execution{status: :running} = execution) do
    names = ready(execution)

    if names == [] do
      execution_not_running(execution)
    else
      runnables = Enum.map(names, &Map.fetch!(execution.ready, &1))
      executed = execute_runnables(execution, runnables)

      {node_results, execution} =
        names
        |> Enum.zip(executed)
        |> Enum.reduce({[], execution}, fn {node, runnable}, {results, current} ->
          {node_result, current} = apply_public_runnable(current, node, runnable)
          {[node_result | results], current}
        end)

      with {:ok, execution} <- settle(execution) do
        {:ok, Enum.reverse(node_results), execution}
      end
    end
  end

  def wave(%Execution{} = execution), do: execution_not_running(execution)

  @spec continue(Execution.t()) :: {:ok, Execution.t()} | {:error, Exception.t()}
  def continue(%Execution{status: :running} = execution) do
    with {:ok, _node_results, execution} <- wave(execution) do
      continue(execution)
    end
  end

  def continue(%Execution{} = execution), do: {:ok, execution}

  defp settle(%Execution{} = execution) do
    {workflow, runnables} = Workflow.prepare_for_dispatch(execution.workflow)
    execution = %{execution | workflow: workflow, ready: %{}, ready_nodes: []}
    {public, internal} = partition_runnables(execution, runnables)

    cond do
      internal != [] ->
        execution = apply_internal_runnables(execution, internal)
        settle(execution)

      public != [] ->
        {ready_nodes, ready} =
          public
          |> Enum.sort_by(fn %Runnable{node: %Step{name: name}} ->
            Map.fetch!(execution.node_positions, name)
          end)
          |> Enum.map_reduce(%{}, fn %Runnable{node: %Step{name: name}} = runnable, ready ->
            {name, Map.put(ready, name, runnable)}
          end)

        {:ok, %{execution | status: :running, ready: ready, ready_nodes: ready_nodes}}

      Workflow.is_runnable?(workflow) ->
        error =
          Error.execution_error("flow execution could not make progress", %{
            flow: execution.flow_name,
            phase: :flow_execution
          })

        finalize(%{execution | engine_error: error})

      true ->
        finalize(execution)
    end
  end

  defp partition_runnables(execution, runnables) do
    Enum.split_with(runnables, fn
      %Runnable{node: %Step{name: name}} -> MapSet.member?(execution.node_names, name)
      %Runnable{} -> false
    end)
  end

  defp apply_internal_runnables(execution, runnables) do
    Enum.reduce(runnables, execution, fn runnable, current ->
      executed = Workflow.execute_runnable(runnable)
      workflow = Workflow.apply_runnable(current.workflow, executed)

      case executed do
        %Runnable{status: :failed, error: error} ->
          %{current | workflow: workflow, engine_error: normalize_engine_error(error)}

        %Runnable{} ->
          %{current | workflow: workflow}
      end
    end)
  end

  defp execute_runnables(execution, runnables) do
    element_kinds = element_kinds(execution)

    if Keyword.fetch!(execution.options, :async) do
      spans = Enum.map(runnables, &start_node_span(execution, &1, element_kinds))
      max_concurrency = Keyword.fetch!(execution.options, :max_concurrency)
      executed = execute_async_runnables(runnables, max_concurrency)

      executed
      |> Enum.zip(spans)
      |> Enum.map(fn {runnable, span} ->
        finish_node_span(span, runnable)
        runnable
      end)
    else
      Enum.map(runnables, &execute_runnable(execution, &1, element_kinds))
    end
  end

  defp execute_runnable(execution, runnable) do
    execute_runnable(execution, runnable, element_kinds(execution))
  end

  defp execute_runnable(execution, runnable, element_kinds) do
    span = start_node_span(execution, runnable, element_kinds)
    executed = Workflow.execute_runnable(runnable)
    finish_node_span(span, executed)
    executed
  end

  defp start_node_span(execution, %Runnable{node: %Step{name: name}}, element_kinds) do
    Telemetry.start([:jido, :flow, :node], %{
      execution_id: execution.id,
      flow: execution.flow_name,
      node: name,
      kind: Map.fetch!(element_kinds, name)
    })
  end

  defp finish_node_span(span, %Runnable{status: :completed}), do: Telemetry.stop(span)

  defp finish_node_span(span, %Runnable{node: %Step{name: name}, status: :failed, error: error}) do
    Telemetry.error(span, normalize_node_error(name, error))
  end

  defp finish_node_span(span, %Runnable{node: %Step{name: name}, status: status}) do
    Telemetry.error(
      span,
      Error.execution_error("flow node returned an unsupported execution status", %{
        node: name,
        status: status
      })
    )
  end

  defp element_kinds(%Execution{flow: %Flow{nodes: nodes}}) do
    Map.new(nodes, fn element -> {Element.name(element), Element.kind(element)} end)
  end

  defp execute_async_runnables(runnables, max_concurrency) do
    OrderedTaskRunner.run(
      runnables,
      max_concurrency,
      &Workflow.execute_runnable/1,
      &fail_exited_runnable/2
    )
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

  defp apply_public_runnable(execution, node, %Runnable{} = runnable) do
    workflow = Workflow.apply_runnable(execution.workflow, runnable)
    node_result = to_node_result(node, runnable)

    node_errors =
      case node_result do
        %NodeResult{status: :error, error: error} ->
          Map.put(execution.node_errors, node, error)

        %NodeResult{} ->
          execution.node_errors
      end

    execution = %{
      execution
      | workflow: workflow,
        revision: execution.revision + 1,
        ready: %{},
        ready_nodes: [],
        node_results: Map.put(execution.node_results, node, node_result),
        node_errors: node_errors
    }

    {node_result, execution}
  end

  defp to_node_result(node, %Runnable{status: :completed, result: %Fact{value: output}}) do
    %NodeResult{node: node, status: :ok, output: output, error: nil, attempt: 1}
  end

  defp to_node_result(node, %Runnable{status: :completed, result: output}) do
    %NodeResult{node: node, status: :ok, output: output, error: nil, attempt: 1}
  end

  defp to_node_result(node, %Runnable{status: :failed, error: error}) do
    %NodeResult{
      node: node,
      status: :error,
      output: nil,
      error: normalize_node_error(node, error),
      attempt: 1
    }
  end

  defp to_node_result(node, %Runnable{status: status}) do
    error =
      Error.execution_error("flow node returned an unsupported execution status", %{
        node: node,
        status: status
      })

    %NodeResult{node: node, status: :error, output: nil, error: error, attempt: 1}
  end

  defp normalize_node_error(_node, %NodeError{error: error}), do: error
  defp normalize_node_error(_node, error) when is_exception(error), do: error

  defp normalize_node_error(node, reason) do
    Error.execution_error("flow node failed", %{node: node, reason: reason})
  end

  defp normalize_engine_error(%NodeError{error: error}), do: error
  defp normalize_engine_error(error) when is_exception(error), do: error

  defp normalize_engine_error(reason) do
    Error.execution_error("flow execution engine failed", %{reason: reason})
  end

  defp finalize(%Execution{node_errors: node_errors} = execution)
       when map_size(node_errors) > 0 do
    error =
      execution.ordered_nodes
      |> Enum.find(&Map.has_key?(node_errors, &1))
      |> then(&Map.fetch!(node_errors, &1))

    complete(execution, {:error, error})
  end

  defp finalize(%Execution{engine_error: error} = execution) when not is_nil(error) do
    complete(execution, {:error, error})
  end

  defp finalize(%Execution{} = execution) do
    final_result =
      case Compiler.runtime_result(
             execution.flow,
             execution.workflow,
             execution.input,
             execution.context
           ) do
        {:ok, output} -> execution.finalizer.(output)
        {:error, error} -> {:error, error}
      end

    complete(execution, final_result)
  end

  defp complete(execution, final_result) do
    status = if match?({:ok, _output}, final_result), do: :succeeded, else: :failed
    Telemetry.finish(execution.lifecycle.flow, final_result)

    {:ok,
     %{
       execution
       | status: status,
         ready: %{},
         ready_nodes: [],
         final_result: final_result
     }}
  end

  defp execution_not_running(execution) do
    {:error,
     Error.validation_error("flow execution is not running", %{
       flow: execution.flow_name,
       status: execution.status
     })}
  end
end
