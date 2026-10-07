defmodule Jido.Exec.Flow.RunnableExecutor do
  @moduledoc false

  alias Jido.Exec.Execution
  alias Jido.Exec.Flow.{Collection, Payload, Target}
  alias Jido.Exec.Telemetry
  alias Jido.Exec.Worker
  alias Jido.Exec.Controller
  alias Jido.Flow.Error
  alias Jido.Instruction
  alias Runic.Workflow
  alias Runic.Workflow.FanIn
  alias Runic.Workflow.Runnable

  @doc "Executes one native Runnable with an explicit Task boundary."
  @spec execute(Execution.t(), Runnable.t(), Controller.call()) :: Runnable.t()
  def execute(execution, runnable, call) do
    kind = dispatch_kind(execution, runnable)
    metadata = node_metadata(execution, runnable)

    if kind == :action do
      case Worker.invoke(call, fn ->
             execute_with_metadata(runnable, metadata, call, :action)
           end) do
        {:ok, result} ->
          result

        {:error, error} ->
          {result, _error} = action_failure(execution, runnable, error)
          result
      end
    else
      execute_with_metadata(runnable, metadata, call, kind)
    end
  end

  defp execute_with_metadata(runnable, metadata, call, kind) do
    span = start_span(metadata)
    executed = runnable |> bind(call, kind) |> safely_execute()
    finish_span(span, executed)
    compact_coordination_context(%{executed | context: runnable.context})
  end

  defp bind(runnable, call, kind) do
    context =
      Enum.reduce([:run_context, :meta_context], runnable.context, fn key, context ->
        case Map.get(context, key) do
          %{jido: runtime} = values ->
            invoke =
              case kind do
                :action ->
                  fn work -> work.() end

                _ ->
                  fn work ->
                    case Worker.invoke(call, work) do
                      {:ok, result} -> result
                      {:error, error} -> {:error, :execution, error}
                    end
                  end
              end

            runner = fn instruction, execution_id ->
              Target.invoke(
                instruction,
                execution_id,
                runtime.flow,
                runtime.invocation,
                invoke
              )
            end

            Map.put(context, key, %{values | jido: %{runtime | target_runner: runner}})

          _ ->
            context
        end
      end)

    %{runnable | context: context}
  end

  defp action_failure(execution, runnable, error) do
    %{kind: kind, component_path: path} =
      metadata =
      Map.fetch!(execution.compiled.work_index, runnable.node.hash)

    details = %{node: List.last(path), node_path: path}

    details =
      case kind do
        :step ->
          Map.put(details, :action, metadata.action)

        :map ->
          %Payload{value: token} = runnable.input_fact.value

          Map.merge(details, %{
            target: metadata.action,
            item_index: token.index,
            item_id: token.id
          })

        _ ->
          details
      end

    instruction = Target.new(kind, Instruction.template(:action, metadata.action), details)
    {:error, error} = Target.tag_execution(error, instruction)

    result =
      case metadata do
        %{kind: :map, on_error: :collect_errors} ->
          %Payload{value: token} = runnable.input_fact.value
          complete_value(runnable, Collection.failed_map_item(token, error))

        _ ->
          Runnable.fail(runnable, error)
      end

    {result, error}
  end

  # Let Runic build its result Fact and events from the handled item error.
  # The replacement work only returns data. It does not repeat an expression,
  # validation, Action, or effect. Restore the original node before apply.
  defp complete_value(runnable, value) do
    node = %{runnable.node | work: fn _input, _context -> Payload.new(value) end}
    executed = safely_execute(%{runnable | node: node})
    %{executed | node: runnable.node}
  end

  defp dispatch_kind(execution, runnable) do
    case Map.get(execution.compiled.work_index, runnable.node.hash) do
      %{kind: :step, role: :execute} ->
        :action

      %{kind: :map, role: :map_item} ->
        if match?(%Payload{value: %{kind: :empty}}, runnable.input_fact.value),
          do: :support,
          else: :action

      # Choice selects its Action at runtime. Keep its outer work compound so
      # the selected target owns the Action worker and its failure metadata.
      %{kind: kind, role: :execute} when kind in [:choice, :iterate, :dispatch] ->
        :compound

      %{kind: :reduce, role: :fan_in} ->
        :compound

      _ ->
        :support
    end
  end

  # Runic prepares every FanIn item with a copy of the whole sibling set.
  # The apply phase reads only these keys, so do not send the sibling set back
  # from every worker in a large Map wave.
  defp compact_coordination_context(
         %Runnable{
           node: %FanIn{},
           context: %{fan_in_context: %{mode: :fan_out_reduce} = fan_in_context} = context
         } = runnable
       ) do
    needed = Map.take(fan_in_context, [:mode, :source_fact_hash, :expected_key, :seen_key])
    %{runnable | context: %{context | fan_in_context: needed}}
  end

  defp compact_coordination_context(runnable), do: runnable

  @doc "Executes native Runnables and returns the admitted input prefix in source order."
  @spec execute_many(Execution.t(), [Runnable.t()], Controller.call()) :: [Runnable.t()]
  def execute_many(%Execution{} = execution, runnables, call) when is_list(runnables) do
    if coordination_only?(runnables) do
      execute_serially(execution, runnables, call)
    else
      if Keyword.fetch!(execution.options, :max_concurrency) > 1 and match?([_, _ | _], runnables) do
        execute_concurrently(execution, runnables, call)
      else
        execute_serially(execution, runnables, call)
      end
    end
  end

  # FanIn coordination does not run an Action. Its prepared context can carry
  # the full sibling set. Keep it in one process instead of copying it to a
  # separate Task for every item in a large Map.
  defp coordination_only?(runnables) do
    runnables != [] and
      Enum.all?(runnables, fn
        %Runnable{node: %FanIn{}, context: %{fan_in_context: %{mode: :fan_out_reduce}}} ->
          true

        _ ->
          false
      end)
  end

  defp execute_serially(execution, runnables, call) do
    runnables
    |> Enum.reduce_while([], fn runnable, completed ->
      executed = execute(execution, runnable, call)
      completed = [executed | completed]

      if executed.status == :failed, do: {:halt, completed}, else: {:cont, completed}
    end)
    |> Enum.reverse()
  end

  # Admission depends only on results that this scheduler has received.
  # A worker failure does not stop a dispatch pass that is already running.
  defp execute_concurrently(execution, runnables, call) do
    execute = fn {runnable, metadata, kind} ->
      execute_with_metadata(runnable, metadata, call, kind)
    end

    %{
      call: call,
      kind: &dispatch_kind(execution, &1),
      fail_action: &action_failure(execution, &1, &2),
      limit: Keyword.fetch!(execution.options, :max_concurrency),
      pending: Enum.with_index(runnables),
      active: %{},
      completed: [],
      execute: execute,
      metadata: &node_metadata(execution, &1)
    }
    |> collect()
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp collect(state) do
    case advance(state) do
      {:done, completed} -> completed
      next -> collect(next)
    end
  end

  defp advance(state) do
    cond do
      state.pending != [] and map_size(state.active) < state.limit and
          not Controller.invocation_stopped?(state.call) ->
        dispatch(state)

      map_size(state.active) == 0 ->
        {:done, state.completed}

      true ->
        receive_result(state)
    end
  end

  defp dispatch(%{pending: [{runnable, index} | rest]} = state) do
    # Do not copy the Execution, sibling runnables, or completed results into workers.
    kind = state.kind.(runnable)
    work = worker(state.execute, {runnable, state.metadata.(runnable), kind})

    if kind == :support do
      result = work.()
      %{state | pending: rest, completed: [{index, result} | state.completed]}
    else
      case Worker.start(state.call, work, kind) do
        {:ok, task} ->
          %{
            state
            | pending: rest,
              active: Map.put(state.active, task.ref, {task, runnable, index})
          }

        {:error, reason} ->
          if Controller.invocation?(state.call) do
            Controller.interrupt_invocation(
              state.call,
              Jido.Exec.Error.interrupted_error(:worker, {:start_error, reason}, nil)
            )
          else
            failed = fail_exited_runnable(runnable, {:start_error, reason})
            %{state | pending: [], completed: [{index, failed} | state.completed]}
          end
      end
    end
  end

  defp worker(execute, input), do: fn -> execute.(input) end

  defp receive_result(%{active: active} = state) do
    receive do
      {ref, result} when is_map_key(active, ref) ->
        {task, _runnable, index} = Map.fetch!(active, ref)
        Worker.finish(task)

        %{
          state
          | active: Map.delete(active, ref),
            pending: if(result.status == :failed, do: [], else: state.pending),
            completed: [{index, result} | state.completed]
        }

      {:DOWN, ref, :process, pid, reason} when is_map_key(active, ref) ->
        {_task, runnable, index} = Map.fetch!(active, ref)

        if Controller.invocation?(state.call) do
          error = Jido.Exec.Error.interrupted_error(:worker, {:process_exit, reason}, nil)
          Telemetry.fail_worker(state.call.controller, pid, error)
          Controller.interrupt_invocation(state.call, error)
        end

        {failed, error} =
          if state.kind.(runnable) == :action do
            error =
              Jido.Action.Error.internal_error("Action execution process exited", %{
                reason: reason
              })

            state.fail_action.(runnable, error)
          else
            failed = fail_exited_runnable(runnable, reason)
            {failed, failed.error}
          end

        Telemetry.fail_worker(state.call.controller, pid, error)

        %{
          state
          | active: Map.delete(active, ref),
            pending: if(failed.status == :failed, do: [], else: state.pending),
            completed: [{index, failed} | state.completed]
        }
    end
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
          node_path: [name],
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

  defp authored_component(execution, %Runnable{node: %{name: runnable_name, hash: hash}}) do
    with %{component_path: [name]} <- Map.get(execution.compiled.work_index, hash),
         %{output: ^runnable_name, kind: kind} <-
           Map.get(execution.compiled.component_index, name) do
      {name, kind}
    else
      _ -> nil
    end
  end

  defp authored_component(_execution, _runnable), do: nil

  defp fail_exited_runnable(runnable, reason) do
    Runnable.fail(
      runnable,
      Error.execution_error("flow runnable task exited", %{
        runnable_id: runnable.id,
        node: runnable_name(runnable),
        node_path: [runnable_name(runnable)],
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
