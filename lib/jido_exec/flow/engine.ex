defmodule Jido.Exec.Flow.Engine do
  @moduledoc false

  alias Jido.Action.Telemetry

  alias Jido.Exec.{
    ConcurrencyLimiter,
    Execution,
    ExecutionGuard
  }

  alias Jido.Exec.Flow.RunnableExecutor

  alias Jido.Flow
  alias Jido.Flow.{Compiled, Compiler, Error}
  alias Runic.Workflow
  alias Runic.Workflow.Runnable

  @doc "Creates a paused Flow execution from prepared Flow and Runic data."
  @spec start(
          Flow.t(),
          Compiled.t(),
          map(),
          map(),
          keyword(),
          function(),
          function(),
          String.t(),
          map()
        ) :: {:ok, Execution.t()} | {:error, Exception.t()}
  def start(
        %Flow{} = flow,
        %Compiled{} = compiled,
        input,
        context,
        options,
        finalizer,
        target_runner,
        execution_id,
        lifecycle
      )
      when is_map(input) and is_map(context) and is_list(options) and
             is_function(finalizer, 1) and is_function(target_runner, 5) and
             is_binary(execution_id) and is_map(lifecycle) do
    runtime = %{
      execution_id: execution_id,
      flow: flow.name,
      flow_digest: Flow.Identity.semantic_digest(flow),
      input: input,
      context: context,
      options: options,
      target_runner: target_runner,
      observer: Jido.Exec.Flow.CollectionTelemetry.observer(execution_id, flow.name)
    }

    workflow =
      compiled.workflow
      |> Workflow.put_run_context(%{_global: %{jido: runtime}})
      |> Workflow.plan_eagerly(Compiler.input_frame(input))

    execution = %Execution{
      id: execution_id,
      flow_name: flow.name,
      status: :running,
      revision: 0,
      guard: ExecutionGuard.new(),
      flow: flow,
      compiled: compiled,
      input: input,
      context: context,
      options: options,
      workflow: workflow,
      ready: [],
      runnable_errors: [],
      engine_error: nil,
      finalizer: finalizer,
      final_result: nil,
      lifecycle: lifecycle
    }

    settle(execution)
  end

  @doc "Returns the native Runic runnables that are ready."
  @spec ready(Execution.t()) :: [Runnable.t()]
  def ready(%Execution{ready: ready}), do: ready

  @doc "Returns the current Flow execution status."
  @spec status(Execution.t()) :: :running | :succeeded | :failed
  def status(%Execution{status: status}), do: status

  @doc "Returns the terminal result or an error while execution is running."
  @spec result(Execution.t()) :: {:ok, term()} | {:error, Exception.t()}
  def result(%Execution{status: :running} = execution) do
    {:error,
     Error.invalid_execution_error("flow execution is not complete", %{
       flow: execution.flow_name,
       status: :running,
       ready: Enum.map(ready(execution), & &1.id)
     })}
  end

  def result(%Execution{final_result: result}) when not is_nil(result), do: result

  @doc "Executes the first ready native Runnable."
  @spec step(Execution.t()) ::
          {:ok, Runnable.t(), Execution.t()} | {:error, Exception.t()}
  def step(%Execution{} = execution) do
    case ready(execution) do
      [runnable | _rest] -> step(execution, runnable)
      [] -> execution_not_running(execution)
    end
  end

  @doc "Executes one selected ready native Runnable."
  @spec step(Execution.t(), Runnable.t() | integer()) ::
          {:ok, Runnable.t(), Execution.t()} | {:error, Exception.t()}
  def step(%Execution{status: :running} = execution, %Runnable{id: id}),
    do: step(execution, id)

  def step(%Execution{status: :running} = execution, id) when is_integer(id) do
    with {:ok, runnable} <- fetch_ready(execution, id) do
      mutate(execution, fn ->
        with_concurrency_limiter(execution, fn -> do_step(execution, runnable) end)
      end)
    end
  end

  def step(%Execution{status: :running}, runnable) do
    {:error,
     Error.invalid_execution_error("flow runnable must be a ready Runnable or runnable ID", %{
       runnable: runnable
     })}
  end

  def step(%Execution{} = execution, _runnable), do: execution_not_running(execution)

  @doc "Executes the complete set of Runnables that is currently ready."
  @spec wave(Execution.t()) ::
          {:ok, [Runnable.t()], Execution.t()} | {:error, Exception.t()}
  def wave(%Execution{status: :running} = execution) do
    case ready(execution) do
      [] ->
        execution_not_running(execution)

      _ready ->
        mutate(execution, fn ->
          with_concurrency_limiter(execution, fn -> do_wave(execution) end)
        end)
    end
  end

  def wave(%Execution{} = execution), do: execution_not_running(execution)

  @doc "Runs successive waves until the Flow has a terminal status."
  @spec continue(Execution.t()) :: {:ok, Execution.t()} | {:error, Exception.t()}
  def continue(%Execution{status: :running} = execution) do
    with {:ok, _runnables, execution} <- wave(execution) do
      continue(execution)
    end
  end

  def continue(%Execution{} = execution), do: {:ok, execution}

  defp settle(%Execution{runnable_errors: [_ | _]} = execution), do: finalize(execution)

  defp settle(%Execution{} = execution) do
    {workflow, runnables} = Workflow.prepare_for_dispatch(execution.workflow)
    execution = %{execution | workflow: workflow, ready: runnables}

    cond do
      runnables != [] ->
        {:ok, execution}

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

  defp do_step(execution, runnable) do
    executed = RunnableExecutor.execute(execution, runnable)
    execution = execution |> apply_runnable(executed) |> advance_revision()

    with {:ok, execution} <- settle(execution) do
      {:ok, executed, execution}
    end
  end

  defp do_wave(execution) do
    executed = RunnableExecutor.execute_many(execution, ready(execution))
    execution = executed |> Enum.reduce(execution, &apply_runnable(&2, &1)) |> advance_revision()

    with {:ok, execution} <- settle(execution) do
      {:ok, executed, execution}
    end
  end

  defp apply_runnable(execution, %Runnable{} = runnable) do
    workflow = Workflow.apply_runnable(execution.workflow, runnable)

    errors =
      case runnable do
        %Runnable{status: :failed, error: error} ->
          execution.runnable_errors ++
            [%{runnable: runnable, error: normalize_error(runnable, error)}]

        %Runnable{} ->
          execution.runnable_errors
      end

    %{
      execution
      | workflow: workflow,
        ready: [],
        runnable_errors: errors
    }
  end

  defp advance_revision(execution), do: %{execution | revision: execution.revision + 1}

  defp fetch_ready(execution, id) do
    case Enum.find(execution.ready, &(&1.id == id)) do
      %Runnable{} = runnable ->
        {:ok, runnable}

      nil ->
        {:error,
         Error.invalid_execution_error("flow runnable is not ready", %{
           flow: execution.flow_name,
           runnable_id: id,
           ready: Enum.map(execution.ready, & &1.id)
         })}
    end
  end

  defp normalize_error(_runnable, error) when is_exception(error), do: error

  defp normalize_error(runnable, reason) do
    Error.execution_error("flow runnable failed", %{
      runnable_id: runnable.id,
      node: runnable_name(runnable),
      reason: reason
    })
  end

  defp runnable_name(%Runnable{node: %{name: name}}), do: name
  defp runnable_name(%Runnable{node: node}), do: node.__struct__

  defp finalize(%Execution{runnable_errors: errors} = execution) when errors != [] do
    failures =
      Enum.map(errors, fn %{runnable: runnable, error: error} ->
        %{node: runnable_name(runnable), runnable_id: runnable.id, error: error}
      end)

    error =
      case failures do
        [%{error: error}] -> error
        failures -> Error.flow_failure(execution.flow_name, failures)
      end

    complete(execution, {:error, error})
  end

  defp finalize(%Execution{engine_error: error} = execution) when not is_nil(error) do
    complete(execution, {:error, error})
  end

  defp finalize(%Execution{} = execution) do
    final_result =
      case Compiler.runtime_result(
             execution.compiled,
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
         ready: [],
         final_result: final_result
     }}
  end

  defp with_concurrency_limiter(execution, fun) do
    ConcurrencyLimiter.with_limiter(
      execution.id,
      Keyword.fetch!(execution.options, :max_concurrency),
      Keyword.fetch!(execution.options, :async),
      fun
    )
  end

  defp mutate(execution, fun) do
    with {:ok, operation} <- ExecutionGuard.claim(execution) do
      mutation = run_mutation(execution, operation, fun)
      finish_mutation(execution, operation, mutation)
    end
  end

  defp run_mutation(execution, operation, fun) do
    fun.()
  catch
    kind, reason ->
      stacktrace = __STACKTRACE__
      :ok = ExecutionGuard.interrupt(operation, execution)
      :erlang.raise(kind, reason, stacktrace)
  end

  defp finish_mutation(execution, operation, {:ok, _result, %Execution{} = next} = mutation) do
    :ok = ExecutionGuard.advance(operation, execution, next)
    mutation
  end

  defp finish_mutation(execution, operation, {:error, _error} = mutation) do
    :ok = ExecutionGuard.release(operation, execution)
    mutation
  end

  defp execution_not_running(execution) do
    {:error,
     Error.invalid_execution_error("flow execution is not running", %{
       flow: execution.flow_name,
       status: execution.status
     })}
  end
end
