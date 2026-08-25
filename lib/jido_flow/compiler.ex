defmodule Jido.Flow.Compiler do
  @moduledoc false

  alias Jido.Action.Error
  alias Jido.Flow
  alias Jido.Flow.Choice
  alias Jido.Flow.Compiler.Choice, as: ChoiceCompiler
  alias Jido.Flow.Compiler.Expression
  alias Jido.Flow.Compiler.Iterator, as: IteratorCompiler
  alias Jido.Flow.Compiler.Map, as: MapCompiler
  alias Jido.Flow.Compiler.Reduce, as: ReduceCompiler
  alias Jido.Flow.Compiler.Target
  alias Jido.Flow.Compiler.TargetContext
  alias Jido.Flow.Component
  alias Jido.Flow.Graph
  alias Jido.Flow.Identity
  alias Jido.Flow.Iterate
  alias Jido.Flow.Map, as: FlowMap
  alias Jido.Flow.NodeError
  alias Jido.Flow.Reduce
  alias Jido.Flow.Step, as: FlowStep
  alias Jido.Flow.Subflow
  alias Runic.Workflow
  alias Runic.Workflow.Step

  @type target_phase :: :input | :execution | :output
  @type target_runner ::
          (module(), term(), map(), String.t(), TargetContext.t() ->
             {:ok, term()} | {:error, target_phase(), Exception.t()})

  @type observer :: (term() -> term())

  @type node_state :: %{
          execution_id: String.t(),
          flow: String.t(),
          flow_digest: String.t(),
          input: map(),
          context: map(),
          results: map(),
          options: keyword(),
          map_nodes: MapSet.t(String.t()),
          target_runner: target_runner(),
          observer: observer()
        }

  @doc false
  @spec runtime_workflow_validated(
          Flow.t(),
          map(),
          map(),
          keyword(),
          target_runner(),
          String.t()
        ) ::
          {:ok, Workflow.t(), [Component.t()]} | {:error, Exception.t()}
  def runtime_workflow_validated(
        %Flow{} = flow,
        input,
        context,
        options,
        target_runner,
        execution_id
      ) do
    runtime_workflow_validated(
      flow,
      input,
      context,
      options,
      target_runner,
      execution_id,
      &ignore_observation/1
    )
  end

  @doc false
  @spec runtime_workflow_validated(
          Flow.t(),
          map(),
          map(),
          keyword(),
          target_runner(),
          String.t(),
          observer()
        ) ::
          {:ok, Workflow.t(), [Component.t()]} | {:error, Exception.t()}
  def runtime_workflow_validated(
        %Flow{} = flow,
        input,
        context,
        options,
        target_runner,
        execution_id,
        observer
      )
      when is_map(input) and is_map(context) and is_list(options) and
             is_function(target_runner, 5) and is_binary(execution_id) and
             is_function(observer, 1) do
    node_state = %{
      execution_id: execution_id,
      flow: flow.name,
      flow_digest: Identity.semantic_digest(flow),
      input: input,
      context: context,
      results: %{},
      options: options,
      target_runner: target_runner,
      observer: observer,
      map_nodes:
        flow.components
        |> Enum.filter(&match?(%FlowMap{}, &1))
        |> MapSet.new(&Component.name_of/1)
    }

    build(flow, node_state)
  end

  def runtime_workflow_validated(
        %Flow{},
        _input,
        _context,
        _options,
        _target_runner,
        _execution_id,
        _observer
      ) do
    {:error, Error.validation_error("flow input and context must be maps")}
  end

  defp ignore_observation({:start, _kind, _metadata}), do: nil
  defp ignore_observation({:stop, _span}), do: :ok
  defp ignore_observation({:error, _span, _error}), do: :ok

  @doc false
  @spec runtime_result(Flow.t(), Workflow.t(), map(), map()) ::
          {:ok, term()} | {:error, Exception.t()}
  def runtime_result(%Flow{} = flow, %Workflow{} = workflow, input, context)
      when is_map(input) and is_map(context) do
    Expression.extract_return(flow.output, workflow, input, context)
  end

  defp build(%Flow{} = flow, node_state) do
    ordered = Graph.canonical_components(flow.components)

    workflow =
      Enum.reduce(ordered, Workflow.new(flow.name), fn node, workflow ->
        add_step(workflow, node, build_step(node, node_state))
      end)

    {:ok, workflow, ordered}
  end

  defp build_step(node, node_state) do
    Step.new(
      name: node.name,
      work: fn parent_value -> run_node(node, parent_value, node_state) end
    )
  end

  defp add_step(workflow, element, step) do
    case Component.effective_dependencies(element) do
      [] -> Workflow.add(workflow, step, validate: :off)
      [dep] -> Workflow.add(workflow, step, to: dep, validate: :off)
      deps -> Workflow.add(workflow, step, to: deps, validate: :off)
    end
  end

  defp run_node(node, parent_value, node_state) do
    case run_node_result(node, parent_value, node_state) do
      {:ok, output} ->
        output

      {:ok, output, _metadata} ->
        output

      {:error, error, _state} ->
        raise_node_error(node, error)

      {:error, error, _state, _metadata} ->
        raise_node_error(node, error)
    end
  end

  defp run_node_result(%Choice{} = choice, parent_value, node_state) do
    state = %{node_state | results: dependency_results(choice, parent_value)}
    ChoiceCompiler.run(choice, state)
  end

  defp run_node_result(%FlowMap{} = map, parent_value, node_state) do
    state = %{node_state | results: dependency_results(map, parent_value)}

    case Expression.resolve(map.collection, state) do
      {:ok, collection} -> MapCompiler.run(map, collection, state)
      {:error, error} -> {:error, error, state}
    end
  end

  defp run_node_result(%Reduce{} = reduce, parent_value, node_state) do
    state = %{node_state | results: dependency_results(reduce, parent_value)}

    case Expression.resolve(reduce.collection, state) do
      {:ok, collection} -> ReduceCompiler.run(reduce, collection, state)
      {:error, error} -> {:error, error, state}
    end
  end

  defp run_node_result(%Iterate{} = iterator, parent_value, node_state) do
    state = %{node_state | results: dependency_results(iterator, parent_value)}
    IteratorCompiler.run(iterator, state)
  end

  defp run_node_result(%FlowStep{} = node, parent_value, node_state) do
    state = %{node_state | results: dependency_results(node, parent_value)}

    case Expression.resolve(node.params, state) do
      {:ok, params} ->
        case run_resolved_node(node, node.action, params, state) do
          {:ok, output} -> {:ok, output}
          {:error, error} -> {:error, error, state}
        end

      {:error, error} ->
        {:error, error, state}
    end
  end

  # Phase one keeps a Subflow as one outer runnable. Phase two will replace this
  # adapter with the native Runic Workflow boundary described in the plan.
  defp run_node_result(%Subflow{} = subflow, parent_value, node_state) do
    state = %{node_state | results: dependency_results(subflow, parent_value)}

    case Expression.resolve(subflow.params, state) do
      {:ok, params} ->
        case run_resolved_node(subflow, subflow.flow, params, state) do
          {:ok, output} -> {:ok, output}
          {:error, error} -> {:error, error, state}
        end

      {:error, error} ->
        {:error, error, state}
    end
  end

  defp run_resolved_node(node, target, params, state) do
    Target.run(
      target,
      params,
      state.context,
      TargetContext.node(node),
      state.execution_id,
      state.target_runner
    )
  end

  defp dependency_results(component, parent_value) do
    dependency_results_for(Component.effective_dependencies(component), parent_value)
  end

  defp dependency_results_for([], _parent_value), do: %{}
  defp dependency_results_for([dep], parent_value), do: %{dep => parent_value}

  defp dependency_results_for(deps, parent_values) when is_list(parent_values) do
    # Multi-parent nodes are attached with `to: deps`; engine joins preserve that same order.
    deps
    |> Enum.zip(parent_values)
    |> Map.new()
  end

  defp raise_node_error(node, error), do: raise(NodeError, node: node.name, error: error)
end
