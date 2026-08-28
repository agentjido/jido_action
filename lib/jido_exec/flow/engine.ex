defmodule Jido.Exec.Flow.Engine do
  @moduledoc false

  alias Jido.Exec.{Execution, ExecutionGuard}
  alias Jido.Exec.Continuation
  alias Jido.Exec.Telemetry
  alias Jido.Executable

  alias Jido.Exec.Flow.RunnableExecutor
  alias Jido.Exec.Flow.Adapter, as: FlowAdapter

  alias Jido.Flow
  alias Jido.Flow.{Compiled, Compiler, Error}
  alias Runic.Workflow
  alias Runic.Workflow.{Fact, Runnable}
  alias Runic.Workflow.Events.{FactProduced, MapReduceTracked, RunnableActivated}

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
      continuations: [],
      continuation_nodes: %{},
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
      mutate(execution, fn -> do_step(execution, runnable) end)
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
        mutate(execution, fn -> do_wave(execution) end)
    end
  end

  def wave(%Execution{} = execution), do: execution_not_running(execution)

  @doc "Runs successive waves until the Flow has a terminal status."
  @spec continue(Execution.t()) :: {:ok, Execution.t()} | {:error, Exception.t()}
  def continue(%Execution{status: :running} = execution) do
    mutation = mutate(execution, fn -> do_continue(execution) end)

    case mutation do
      {:ok, :continued, execution} -> {:ok, execution}
      {:error, _error} = error -> error
    end
  end

  def continue(%Execution{} = execution), do: {:ok, execution}

  defp settle(%Execution{runnable_errors: [_ | _]} = execution), do: finalize(execution)

  defp settle(%Execution{engine_error: error} = execution) when not is_nil(error),
    do: finalize(execution)

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
    {executed, execution} = apply_executed(execution, executed)
    execution = advance_revision(execution)

    with {:ok, execution} <- settle(execution) do
      {:ok, executed, execution}
    end
  end

  defp do_wave(execution) do
    executed = RunnableExecutor.execute_many(execution, ready(execution))

    {executed, candidate} =
      Enum.map_reduce(executed, execution, fn runnable, current ->
        apply_executed(current, runnable)
      end)

    execution =
      if candidate.engine_error do
        %{execution | ready: [], engine_error: candidate.engine_error}
      else
        candidate
      end

    execution = advance_revision(execution)

    with {:ok, execution} <- settle(execution) do
      {:ok, executed, execution}
    end
  end

  defp do_continue(%Execution{status: :running} = execution) do
    with {:ok, _runnables, execution} <- do_wave(execution) do
      do_continue(execution)
    end
  end

  defp do_continue(%Execution{} = execution), do: {:ok, :continued, execution}

  defp apply_runnable(execution, %Runnable{} = runnable) do
    workflow = apply_runic_runnable(execution.workflow, runnable)

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

  defp apply_executed(
         execution,
         %Runnable{status: :failed, node: %{hash: hash}} = runnable
       ) do
    case Map.get(execution.continuation_nodes, hash) do
      %{role: :target} = pending ->
        recover_continuation_failure(execution, runnable, pending)

      _other ->
        {runnable, apply_runnable(execution, runnable)}
    end
  end

  defp apply_executed(
         execution,
         %Runnable{status: :completed, result: %Fact{value: %Continuation{} = continuation}} =
           runnable
       ) do
    case attach_continuation(execution, runnable, continuation) do
      {:ok, sanitized, execution} ->
        {sanitized, execution}

      {:recovered, sanitized, execution} ->
        {sanitized, apply_runnable(execution, sanitized)}

      {:error, error, sanitized} ->
        {sanitized, %{execution | ready: [], engine_error: error}}
    end
  end

  defp apply_executed(execution, %Runnable{} = runnable) do
    runnable = normalize_continuation_events(execution, runnable)
    {runnable, apply_runnable(execution, runnable)}
  end

  defp attach_continuation(execution, runnable, continuation) do
    with :ok <- Continuation.claim(execution.options, continuation.origin_action),
         {:ok, executable} <- resolve_continuation_target(continuation),
         sequence = length(execution.continuations) + 1,
         {:ok, region} <-
           prepare_continuation_region(executable, continuation, sequence) do
      prefix = "$continue/#{sequence}"
      finalizer_name = "#{prefix}/result"
      finalizer = Compiler.continuation_finalizer_step(finalizer_name, continuation)
      origin = continuation_origin(execution, runnable)
      mapped? = not is_nil(origin.map_tracking)
      map_tracking = origin.map_tracking

      old_successors =
        execution.workflow
        |> Workflow.next_steps(runnable.node)
        |> Enum.reject(&continuation_support_node?/1)

      workflow =
        execution.workflow
        |> Workflow.add(region.workflow, to: runnable.node, validate: :off)
        |> Workflow.add(finalizer, to: region.output, validate: :off)
        |> connect_successors(finalizer, old_successors)

      {sanitized, fact} =
        sanitize_continuation_runnable(runnable, region.input, sequence, mapped?)

      workflow = workflow |> Workflow.log_fact(fact) |> Workflow.apply_events(sanitized.events)

      workflow =
        Enum.reduce(region.entries, workflow, fn entry, current ->
          activation = %RunnableActivated{
            fact_hash: fact.hash,
            node_hash: entry.hash,
            activation_kind: activation_kind(entry)
          }

          Workflow.apply_event(current, activation)
        end)

      target = target_identity(executable, region)
      occurrence = continuation_occurrence(origin, continuation, target)

      record = %{
        sequence: sequence,
        occurrence: occurrence,
        parent: origin.parent_occurrence,
        depth: origin.depth + 1,
        kind: executable.kind,
        target: target,
        origin: continuation.origin_action,
        node: runnable_name(runnable)
      }

      {:ok, sanitized,
       %{
         execution
         | workflow: workflow,
           ready: [],
           continuations: execution.continuations ++ [record],
           continuation_nodes:
             execution.continuation_nodes
             |> put_continuation_targets(
               region.workflow,
               finalizer,
               continuation,
               occurrence,
               origin.depth + 1
             )
             |> put_continuation_node(
               finalizer,
               origin.origin_hash,
               map_tracking,
               occurrence,
               origin.depth + 1
             )
       }}
    else
      {:error, error} ->
        if recoverable_attachment_error?(error) do
          case Continuation.fail(continuation, error) do
            {:ok, value} ->
              {:recovered, recover_rejected_continuation_runnable(runnable, value), execution}

            {:error, routed_error} ->
              close_continuation_span(continuation, routed_error)
              {:error, routed_error, reject_continuation_runnable(runnable)}
          end
        else
          close_continuation_span(continuation, error)
          {:error, error, reject_continuation_runnable(runnable)}
        end
    end
  end

  defp recoverable_attachment_error?(%{message: "continuation limit exceeded"}), do: false
  defp recoverable_attachment_error?(_error), do: true

  defp resolve_continuation_target(continuation) do
    with {:ok, executable} <- Executable.resolve(continuation.target),
         :ok <- Executable.validate(executable) do
      {:ok, executable}
    else
      {:error, cause} ->
        {:error,
         Jido.Action.Error.execution_error("action returned an invalid continuation target", %{
           action: continuation.origin_action,
           target: continuation.target,
           cause: cause,
           retry: false
         })}
    end
  end

  defp prepare_continuation_region(
         %Executable{kind: :action, target: target},
         continuation,
         sequence
       ) do
    name = "$continue/#{sequence}/target"
    target_step = Compiler.continuation_action_step(name, target, continuation.owner)
    workflow = Workflow.new(name: "$continue/#{sequence}") |> Workflow.add(target_step)

    {:ok,
     %{
       workflow: workflow,
       entries: [target_step],
       output: target_step,
       input: {:jido_continuation_input, sequence, continuation.frame, continuation.input},
       flow: nil
     }}
  end

  defp prepare_continuation_region(
         %Executable{kind: :flow} = executable,
         continuation,
         sequence
       ) do
    namespace = ["$continue", Integer.to_string(sequence)]

    with {:ok, flow, input, workflow, output} <-
           FlowAdapter.prepare_continuation(executable, continuation.input, namespace) do
      entries = Workflow.next_steps(workflow, Workflow.root())

      {:ok,
       %{
         workflow: workflow,
         entries: entries,
         output: output,
         input: {:jido_flow_input, input, continuation.frame},
         flow: flow
       }}
    end
  end

  defp connect_successors(workflow, finalizer, successors) do
    Enum.reduce(successors, workflow, fn successor, current ->
      Workflow.draw_connection(current, finalizer, successor, :flow)
    end)
  end

  defp sanitize_continuation_runnable(
         %Runnable{result: %Fact{} = result, events: events} = runnable,
         value,
         _sequence,
         mapped?
       ) do
    fact = Fact.new(value: value, ancestry: result.ancestry, meta: result.meta)

    events =
      events
      |> Enum.reject(fn event -> mapped? and match?(%MapReduceTracked{}, event) end)
      |> Enum.reject(fn
        %FactProduced{hash: hash} -> hash == result.hash
        _event -> false
      end)

    {%{runnable | result: fact, events: events}, fact}
  end

  defp reject_continuation_runnable(%Runnable{} = runnable) do
    {sanitized, _fact} =
      sanitize_continuation_runnable(
        runnable,
        {:jido_continuation_rejected, 0},
        0,
        false
      )

    sanitized
  end

  defp recover_rejected_continuation_runnable(
         %Runnable{result: %Fact{} = result, events: events} = runnable,
         value
       ) do
    fact = Fact.new(value: value, ancestry: result.ancestry, meta: result.meta)

    events =
      Enum.map(events, fn
        %FactProduced{hash: hash} = event when hash == result.hash ->
          %{
            event
            | hash: fact.hash,
              value: fact.value,
              ancestry: fact.ancestry,
              meta: fact.meta
          }

        %MapReduceTracked{result_fact_hash: hash} = event when hash == result.hash ->
          %{event | result_fact_hash: fact.hash}

        event ->
          event
      end)

    %{runnable | result: fact, events: events}
  end

  defp activation_kind(entry) do
    case Runic.Workflow.Invokable.match_or_execute(entry) do
      :match -> :matchable
      :execute -> :runnable
    end
  end

  defp target_identity(%Executable{kind: :action, target: target}, _region),
    do: {:action, target}

  defp target_identity(%Executable{kind: :flow}, %{flow: flow}),
    do: {:flow, Flow.Identity.semantic_digest(flow)}

  defp continuation_occurrence(origin, continuation, target) do
    value = {
      :jido_continuation,
      origin.parent_occurrence,
      origin.origin_hash,
      continuation.owner,
      target
    }

    :crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic]))
    |> Base.url_encode64(padding: false)
  end

  defp continuation_support_node?(%{name: "$continue/" <> _rest}), do: true
  defp continuation_support_node?(_node), do: false

  defp mapped_node?(workflow, %{hash: hash}) do
    workflow.mapped
    |> Map.get(:mapped_paths, MapSet.new())
    |> MapSet.member?(hash)
  end

  defp map_tracking_event(_runnable, false), do: nil

  defp map_tracking_event(%Runnable{events: events}, true) do
    Enum.find(events, &match?(%MapReduceTracked{}, &1))
  end

  defp continuation_origin(execution, %Runnable{node: %{hash: hash}} = runnable) do
    case Map.get(execution.continuation_nodes, hash) do
      %{origin_hash: _origin_hash} = origin ->
        origin

      nil ->
        mapped? = mapped_node?(execution.workflow, runnable.node)

        %{
          origin_hash: hash,
          map_tracking: map_tracking_event(runnable, mapped?),
          parent_occurrence: nil,
          depth: 0
        }
    end
  end

  defp put_continuation_node(nodes, finalizer, origin_hash, nil, occurrence, depth) do
    Map.put(nodes, finalizer.hash, %{
      role: :finalizer,
      origin_hash: origin_hash,
      map_tracking: nil,
      parent_occurrence: occurrence,
      depth: depth
    })
  end

  defp put_continuation_node(
         nodes,
         finalizer,
         origin_hash,
         %MapReduceTracked{} = tracking,
         occurrence,
         depth
       ) do
    Map.put(nodes, finalizer.hash, %{
      role: :finalizer,
      origin_hash: origin_hash,
      map_tracking: tracking,
      parent_occurrence: occurrence,
      depth: depth
    })
  end

  defp put_continuation_targets(
         nodes,
         workflow,
         finalizer,
         continuation,
         parent_occurrence,
         depth
       ) do
    workflow.graph
    |> Multigraph.vertices()
    |> Enum.filter(fn node ->
      is_map(node) and Map.has_key?(node, :hash) and not match?(%Fact{}, node)
    end)
    |> Enum.reduce(nodes, fn node, current ->
      Map.put(current, node.hash, %{
        role: :target,
        origin_hash: node.hash,
        map_tracking: nil,
        parent_occurrence: parent_occurrence,
        depth: depth,
        finalizer_hash: finalizer.hash,
        continuation: continuation
      })
    end)
  end

  defp normalize_continuation_events(
         %{continuation_nodes: nodes},
         %Runnable{node: %{hash: hash}, events: events} = runnable
       )
       when is_list(events) do
    case Map.get(nodes, hash) do
      %{role: :finalizer, origin_hash: origin_hash, map_tracking: nil} ->
        normalize_continuation_result(runnable, events, origin_hash, nil)

      %{role: :finalizer, origin_hash: origin_hash, map_tracking: tracking} ->
        normalize_continuation_result(runnable, events, origin_hash, tracking)

      nil ->
        runnable

      _target ->
        runnable
    end
  end

  defp normalize_continuation_events(_execution, runnable), do: runnable

  defp normalize_continuation_result(runnable, events, origin_hash, tracking) do
    parent_fact_hash =
      case tracking do
        %MapReduceTracked{fan_out_fact_hash: hash} -> hash
        nil -> elem(runnable.result.ancestry, 1)
      end

    result = %{
      runnable.result
      | ancestry: {origin_hash, parent_fact_hash}
    }

    result_hash = result.hash

    events =
      events
      |> Enum.reject(&match?(%MapReduceTracked{}, &1))
      |> Enum.map(fn
        %FactProduced{hash: ^result_hash} = event ->
          %{event | ancestry: result.ancestry}

        event ->
          event
      end)

    events =
      case tracking do
        %MapReduceTracked{} ->
          events ++ [%{tracking | step_hash: origin_hash, result_fact_hash: result_hash}]

        nil ->
          events
      end

    %{runnable | result: result, events: events}
  end

  defp recover_continuation_failure(execution, runnable, pending) do
    error = normalize_error(runnable, runnable.error)

    case Continuation.fail(pending.continuation, error) do
      {:ok, value} ->
        fact =
          Fact.new(
            value: {:jido_continuation_recovered, value},
            ancestry: {runnable.node.hash, runnable.input_fact.hash}
          )

        workflow =
          execution.workflow
          |> Workflow.mark_runnable_as_ran(runnable.node, runnable.input_fact)
          |> Workflow.log_fact(fact)
          |> Workflow.apply_event(%RunnableActivated{
            fact_hash: fact.hash,
            node_hash: pending.finalizer_hash,
            activation_kind: :runnable
          })

        recovered = %{
          runnable
          | status: :completed,
            result: fact,
            events: [],
            error: nil
        }

        {recovered, %{execution | workflow: workflow, ready: []}}

      {:error, routed_error} ->
        close_continuation_span(pending.continuation, routed_error)
        failed = %{runnable | error: routed_error}
        {failed, apply_runnable(execution, failed)}
    end
  end

  defp close_continuation_span(%Continuation{span: nil}, _error), do: :ok

  defp close_continuation_span(%Continuation{span: span}, error) do
    Telemetry.error(span, error)
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

  defp execution_not_running(execution) do
    {:error,
     Error.invalid_execution_error("flow execution is not running", %{
       flow: execution.flow_name,
       status: execution.status
     })}
  end
end
