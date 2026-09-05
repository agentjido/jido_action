defmodule Jido.Exec.Flow.Engine do
  @moduledoc false

  alias Jido.Exec.{Execution, ExecutionGuard, Work}
  alias Jido.Exec.Telemetry
  alias Jido.Exec.Transition

  alias Jido.Exec.Flow.{Inspection, RunnableExecutor}

  alias Jido.Flow
  alias Jido.Flow.{Compiled, Compiler, Error}
  alias Jido.Flow.Compiler.Payload
  alias Runic.Workflow
  alias Runic.Workflow.IdentityConflictError
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
      flow_digest: compiled.semantic_digest,
      context: context,
      options: options,
      target_runner: target_runner,
      observer: Jido.Exec.Flow.CollectionTelemetry.observer(execution_id, flow.name)
    }

    workflow =
      compiled.workflow
      |> Workflow.put_run_context(%{_global: %{jido: runtime}})
      |> Workflow.plan_eagerly(Payload.new(Compiler.input_frame(input)))

    execution = %Execution{
      id: execution_id,
      flow_name: flow.name,
      status: :running,
      revision: 0,
      guard: ExecutionGuard.new(),
      compiled: compiled,
      input: input,
      context: context,
      options: options,
      workflow: workflow,
      ready: [],
      work_ref: make_ref(),
      runnable_errors: [],
      engine_error: nil,
      finalizer: finalizer,
      final_result: nil,
      lifecycle: lifecycle
    }

    settle(execution)
  end

  @doc "Returns small descriptions of the ready work."
  @spec ready(Execution.t()) :: [Work.t()]
  def ready(%Execution{} = execution) do
    Enum.with_index(execution.ready, &Inspection.work(execution, &1, &2))
  end

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
       ready: Enum.map(execution.ready, & &1.id)
     })}
  end

  def result(%Execution{final_result: result}) when not is_nil(result), do: result

  @doc false
  @spec run_to_completion(Execution.t()) ::
          {:ok, Execution.t()} | {:continue, Transition.t()} | {:error, Exception.t()}
  def run_to_completion(%Execution{status: :running} = execution) do
    case mutate(execution, fn -> do_continue(execution) end) do
      {:ok, :continued, execution} -> {:ok, execution}
      {:transition, %Transition{} = transition, _execution} -> {:continue, transition}
      {:error, _error} = error -> error
    end
  end

  def run_to_completion(%Execution{} = execution), do: {:ok, execution}

  @doc "Executes the first ready work unit."
  @spec step(Execution.t()) :: {:ok, Work.t(), Execution.t()} | {:error, Exception.t()}
  def step(%Execution{status: :running, ready: [runnable | _rest]} = execution),
    do: step_at(execution, runnable, 0)

  def step(%Execution{} = execution), do: execution_not_running(execution)

  @doc "Executes one ready unit selected by its revision-scoped token."
  @spec step(Execution.t(), Work.token()) ::
          {:ok, Work.t(), Execution.t()} | {:error, Exception.t()}
  def step(%Execution{status: :running} = execution, token) do
    with {:ok, runnable, position} <- fetch_ready(execution, token) do
      step_at(execution, runnable, position)
    end
  end

  def step(%Execution{} = execution, _token), do: execution_not_running(execution)

  @doc "Executes currently ready units, stopping new dispatch on failure."
  @spec wave(Execution.t()) :: {:ok, [Work.t()], Execution.t()} | {:error, Exception.t()}
  def wave(%Execution{status: :running, ready: [_ | _]} = execution) do
    with {:ok, executed, next} <-
           execution
           |> mutate(fn -> do_wave(execution) end)
           |> reject_stepwise_transition(execution) do
      # The executor returns the admitted input prefix in source order.
      # Positions remain distinct even when native IDs are equal.
      work = Enum.with_index(executed, &Inspection.work(execution, &1, &2))
      {:ok, work, next}
    end
  end

  def wave(%Execution{} = execution), do: execution_not_running(execution)

  @doc "Runs successive waves until the Flow has a terminal status."
  @spec continue(Execution.t()) :: {:ok, Execution.t()} | {:error, Exception.t()}
  def continue(%Execution{status: :running} = execution) do
    mutation = mutate(execution, fn -> do_continue(execution) end)

    case reject_stepwise_transition(mutation, execution) do
      {:ok, :continued, execution} -> {:ok, execution}
      {:error, _error} = error -> error
    end
  end

  def continue(%Execution{} = execution), do: {:ok, execution}

  defp settle(%Execution{engine_error: error} = execution) when not is_nil(error),
    do: finalize(execution)

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

  defp step_at(execution, runnable, position) do
    with {:ok, executed, next} <-
           execution
           |> mutate(fn -> do_step(execution, runnable) end)
           |> reject_stepwise_transition(execution) do
      {:ok, Inspection.work(execution, executed, position), next}
    end
  end

  defp do_step(execution, runnable) do
    executed = RunnableExecutor.execute(execution, runnable)
    execution = execution |> apply_runnable(executed) |> advance_revision()

    case settle(execution) do
      {:ok, execution} -> {:ok, executed, execution}
      {:transition, transition, execution} -> {:transition, transition, execution}
    end
  end

  defp do_wave(execution) do
    executed = RunnableExecutor.execute_many(execution, execution.ready)
    execution = executed |> Enum.reduce(execution, &apply_runnable(&2, &1)) |> advance_revision()

    case settle(execution) do
      {:ok, execution} -> {:ok, executed, execution}
      {:transition, transition, execution} -> {:transition, transition, execution}
    end
  end

  defp do_continue(%Execution{status: :running} = execution) do
    case do_wave(execution) do
      {:ok, _runnables, execution} -> do_continue(execution)
      {:transition, transition, execution} -> {:transition, transition, execution}
    end
  end

  defp do_continue(%Execution{} = execution), do: {:ok, :continued, execution}

  defp apply_runnable(%Execution{engine_error: error} = execution, _runnable)
       when not is_nil(error),
       do: execution

  defp apply_runnable(execution, %Runnable{} = runnable) do
    workflow = apply_runic_runnable(execution.workflow, runnable)

    errors =
      case runnable do
        %Runnable{status: :failed, error: error} ->
          execution.runnable_errors ++
            [
              %{
                node: runnable_name(runnable),
                runnable_id: runnable.id,
                error: normalize_error(runnable, error)
              }
            ]

        %Runnable{} ->
          execution.runnable_errors
      end

    %{
      execution
      | workflow: workflow,
        ready: [],
        runnable_errors: errors
    }
  rescue
    error in IdentityConflictError ->
      failure =
        Error.ExecutionFailureError.exception(
          message: "flow graph identity conflict",
          details: %{
            flow: execution.flow_name,
            phase: :flow_identity,
            cause: IdentityConflictError,
            identity: error.identity,
            context: error.context,
            existing: error.existing,
            incoming: error.incoming,
            retry: false
          },
          stacktrace: __STACKTRACE__,
          splode: Error
        )

      %{execution | engine_error: failure, ready: []}
  end

  # Runic's failed-runnable clause emits an unconditional warning. Jido owns
  # the handled failure through its return value and telemetry, so use the two
  # public Runic state transitions from that clause without the duplicate log.
  defp apply_runic_runnable(workflow, %Runnable{
         status: :failed,
         node: node,
         input_fact: fact
       }) do
    workflow
    |> Workflow.mark_runnable_as_ran(node, fact)
    |> Workflow.skip_downstream_subgraph(node)
  end

  defp apply_runic_runnable(workflow, runnable) do
    Workflow.apply_runnable(workflow, runnable)
  end

  defp advance_revision(execution), do: %{execution | revision: execution.revision + 1}

  defp fetch_ready(execution, token) do
    with {:ok, position} <- Work.position(token, execution.work_ref, execution.revision),
         {:ok, runnable} <- Enum.fetch(execution.ready, position) do
      {:ok, runnable, position}
    else
      :error ->
        {:error,
         Error.invalid_execution_error("invalid flow work token", %{
           flow: execution.flow_name,
           execution_id: execution.id,
           revision: execution.revision,
           reason: :invalid_work_token
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

  defp finalize(%Execution{engine_error: error} = execution) when not is_nil(error) do
    complete(execution, {:error, error})
  end

  defp finalize(%Execution{runnable_errors: errors} = execution) when errors != [] do
    failures = Enum.sort_by(errors, & &1.node)

    error =
      case failures do
        [%{error: error}] -> error
        failures -> Error.flow_failure(execution.flow_name, failures)
      end

    complete(execution, {:error, error})
  end

  defp finalize(%Execution{} = execution) do
    case Compiler.runtime_result(
           execution.compiled,
           execution.workflow,
           execution.input,
           execution.context
         ) do
      {:continue, %Transition{} = transition} -> complete_transition(execution, transition)
      {:ok, output} -> complete(execution, execution.finalizer.(output))
      {:error, error} -> complete(execution, {:error, error})
    end
  end

  defp complete(execution, final_result) do
    status = if match?({:ok, _output}, final_result), do: :succeeded, else: :failed

    Telemetry.finish(execution.lifecycle.flow, final_result)

    {:ok,
     %{
       execution
       | status: status,
         ready: [],
         finalizer: nil,
         final_result: final_result
     }}
  end

  defp complete_transition(execution, %Transition{} = transition) do
    Telemetry.finish(execution.lifecycle.flow, {:continue, transition})

    {:transition, transition,
     %{
       execution
       | status: :succeeded,
         ready: [],
         finalizer: nil,
         final_result: nil
     }}
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

  defp finish_mutation(
         execution,
         operation,
         {:transition, %Transition{}, %Execution{} = next} = mutation
       ) do
    :ok = ExecutionGuard.advance(operation, execution, next)
    mutation
  end

  defp reject_stepwise_transition(
         {:transition, %Transition{}, %Execution{} = next},
         _execution
       ) do
    {:error,
     Error.invalid_execution_error("step-wise execution does not support Dispatch", %{
       flow: next.flow_name,
       component: :dispatch
     })}
  end

  defp reject_stepwise_transition(result, _execution), do: result

  defp execution_not_running(execution) do
    {:error,
     Error.invalid_execution_error("flow execution is not running", %{
       flow: execution.flow_name,
       status: execution.status
     })}
  end
end
