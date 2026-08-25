defmodule Jido.Flow.Compiler.Iterator do
  @moduledoc false

  alias Jido.Flow.Error
  alias Jido.Action.Validation
  alias Jido.Flow.Compiler.Condition
  alias Jido.Flow.Compiler.Expression
  alias Jido.Flow.Compiler.Target
  alias Jido.Flow.Identity

  @doc false
  @spec run(Jido.Flow.Iterate.t(), map()) ::
          {:ok, term()} | {:error, Exception.t(), map()}
  def run(iterator, state) do
    run_resolved_iterator(iterator, state)
  rescue
    exception -> iterator_internal_failure(iterator, state, exception.__struct__)
  catch
    kind, _reason -> iterator_internal_failure(iterator, state, kind)
  end

  defp run_resolved_iterator(iterator, state) do
    with {:ok, candidate} <- Expression.resolve(iterator.state.initial, state),
         {:ok, candidate} <-
           validate_plain_iterator_state(iterator, candidate, :initial, nil, nil, 0),
         {:ok, iterator_state} <-
           validate_iterator_state_schema(iterator, candidate, :initial, nil, nil, 0) do
      runtime = %{
        state: iterator_state,
        revision: 0,
        completed: 0,
        body_result: nil
      }

      case evaluate_iterator_completion(iterator, state, runtime) do
        {:ok, true} -> iterator_complete(iterator, state, runtime)
        {:ok, false} -> run_iterator_iteration(iterator, state, runtime)
        {:error, error} -> iterator_fail(iterator, state, runtime, error)
      end
    else
      {:error, error} ->
        runtime = %{state: nil, revision: 0, completed: 0, body_result: nil}
        iterator_fail(iterator, state, runtime, error)
    end
  end

  defp run_iterator_iteration(iterator, state, runtime) do
    index = runtime.completed
    iteration_id = Identity.iteration_uuid(state.flow_digest, iterator.name, index)

    span =
      state.observer.({
        :start,
        :iterate_iteration,
        %{
          node: iterator.name,
          target: iterator.action,
          iteration_index: index,
          iteration_id: iteration_id,
          state_revision: runtime.revision
        }
      })

    local_state =
      state
      |> Map.put(:iterate_state, runtime.state)
      |> Map.put(:iteration_index, index)
      |> Map.put(:body_result, runtime.body_result)

    target_context =
      Target.iterator(iterator, index, iteration_id, runtime.revision)

    result =
      try do
        with {:ok, params} <-
               Expression.resolve(iterator.params, local_state)
               |> Target.tag_validation(target_context),
             {:ok, output} <-
               Target.run(
                 iterator.action,
                 params,
                 state.context,
                 target_context,
                 state.execution_id,
                 state.target_runner
               ),
             update_state =
               local_state
               |> Map.put(:body_result, output),
             {:ok, candidate} <- Expression.resolve(iterator.state.update, update_state),
             {:ok, candidate} <-
               validate_plain_iterator_state(
                 iterator,
                 candidate,
                 :update,
                 index,
                 iteration_id,
                 runtime.revision
               ),
             {:ok, next_state} <-
               validate_iterator_state_schema(
                 iterator,
                 candidate,
                 :update,
                 index,
                 iteration_id,
                 runtime.revision
               ) do
          next_runtime = %{
            state: next_state,
            revision: runtime.revision + 1,
            completed: runtime.completed + 1,
            body_result: output
          }

          case evaluate_iterator_completion(iterator, state, next_runtime) do
            {:ok, completed?} -> {:ok, completed?, next_runtime}
            {:error, error} -> {:error, error, next_runtime}
          end
        else
          {:error, error} -> {:error, error, runtime}
        end
      rescue
        exception -> {:internal_error, exception.__struct__}
      catch
        kind, _reason -> {:internal_error, kind}
      end

    case result do
      {:ok, completed?, next_runtime} ->
        state.observer.({:stop, span})
        continue_iterator_after_iteration(iterator, state, next_runtime, completed?)

      {:error, error, failure_runtime} ->
        state.observer.({:error, span, error})
        iterator_fail(iterator, state, failure_runtime, error)

      {:internal_error, error_type} ->
        error = iterator_internal_error(iterator, index, runtime.revision, error_type)
        state.observer.({:error, span, error})
        iterator_fail(iterator, state, runtime, error)
    end
  end

  defp continue_iterator_after_iteration(iterator, state, runtime, true),
    do: iterator_complete(iterator, state, runtime)

  defp continue_iterator_after_iteration(iterator, state, runtime, false)
       when runtime.completed == iterator.max_iterations,
       do: iterator_exhaust(iterator, state, runtime)

  defp continue_iterator_after_iteration(iterator, state, runtime, false),
    do: run_iterator_iteration(iterator, state, runtime)

  defp iterator_complete(_iterator, _state, runtime) do
    output = %{
      kind: :jido_flow_iterate_result,
      iterations: runtime.completed,
      state: runtime.state,
      output: runtime.body_result
    }

    {:ok, output}
  end

  defp iterator_exhaust(iterator, state, runtime) do
    error =
      Error.execution_error("flow iterator exhausted maximum iterations", %{
        phase: :iterate_exhaustion,
        node: iterator.name,
        max_iterations: iterator.max_iterations,
        completed_iterations: runtime.completed,
        state_revision: runtime.revision,
        retry: false
      })

    {:error, error, state}
  end

  defp iterator_fail(_iterator, state, _runtime, error), do: {:error, error, state}

  defp iterator_internal_failure(iterator, state, error_type) do
    error = iterator_internal_error(iterator, nil, 0, error_type)

    iterator_fail(
      iterator,
      state,
      %{state: nil, revision: 0, completed: 0, body_result: nil},
      error
    )
  end

  defp iterator_internal_error(iterator, iteration_index, state_revision, error_type) do
    Error.internal_error("flow iterator adapter failed", %{
      phase: :iterate_internal,
      node: iterator.name,
      iteration_index: iteration_index,
      state_revision: state_revision,
      error_type: error_type,
      retry: false
    })
  end

  defp validate_plain_iterator_state(iterator, value, phase, index, iteration_id, revision) do
    if is_map(value) and not is_struct(value) do
      {:ok, value}
    else
      message =
        if phase == :initial,
          do: "iterator initial state must resolve to a plain map",
          else: "iterator state update must resolve to a plain map"

      {:error,
       Error.execution_error(message, %{
         phase: iterator_state_phase(phase),
         node: iterator.name,
         iteration_index: index,
         iteration_id: iteration_id,
         state_revision: revision,
         reason: :not_a_plain_map,
         value_type: Expression.value_type(value),
         retry: false
       })}
    end
  end

  defp validate_iterator_state_schema(iterator, value, phase, index, iteration_id, revision) do
    details = %{
      phase: iterator_state_phase(phase),
      node: iterator.name,
      iteration_index: index,
      iteration_id: iteration_id,
      state_revision: revision,
      retry: false
    }

    result =
      try do
        Validation.open_validate_preserving_shape(iterator.state.schema, value, %{})
      rescue
        _exception -> {:error, :schema_failure}
      catch
        _kind, _reason -> {:error, :schema_failure}
      end

    case result do
      {:ok, validated} when is_map(validated) and not is_struct(validated) ->
        {:ok, validated}

      {:ok, validated} ->
        {:error,
         Error.execution_error(
           "iterator state schema must return a plain map",
           Map.merge(details, %{
             reason: :not_a_plain_map,
             value_type: Expression.value_type(validated)
           })
         )}

      {:error, _reason} ->
        {:error,
         Error.invalid_execution_error("iterator state schema validation failed", details)}
    end
  end

  defp iterator_state_phase(:initial), do: :iterate_state_initial
  defp iterator_state_phase(:update), do: :iterate_state_update

  defp evaluate_iterator_completion(iterator, state, runtime) do
    local_state =
      state
      |> Map.put(:iterate_state, runtime.state)
      |> Map.put(:iteration_index, runtime.completed)
      |> Map.put(:body_result, runtime.body_result)

    case Condition.evaluate(iterator.completion, local_state, iterator.name, :iterate) do
      {:ok, result} ->
        {:ok, result}

      {:error, error} ->
        details = Map.get(error, :details, %{})

        {:error,
         Error.execution_error("invalid iterator completion condition operands", %{
           phase: :iterate_completion,
           node: iterator.name,
           operator: Map.get(details, :operator),
           reason: Map.get(details, :reason),
           left_type: Map.get(details, :left_type),
           right_type: Map.get(details, :right_type),
           iterations: runtime.completed,
           retry: false
         })}
    end
  end
end
