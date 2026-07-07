defmodule Jido.Flow.Compiler do
  @moduledoc """
  Compiles canonical Flow artifacts into Runic workflows.
  """

  alias Jido.Action.Error
  alias Jido.Action.Output
  alias Jido.Exec
  alias Jido.Flow
  alias Jido.Flow.Node
  alias Jido.Flow.NodeError
  alias Jido.Flow.Ref
  alias Runic.Workflow
  alias Runic.Workflow.Step

  @collector_key :__jido_flow_error_collector__
  @run_option_keys [:async, :max_concurrency]

  @type node_state :: %{
          flow: String.t(),
          input: map(),
          context: map(),
          results: map()
        }

  @doc """
  Compiles a Flow artifact into a shape-accurate Runic workflow.

  The returned workflow is suitable for graph inspection. Runtime input and
  context are only available through `run/3`.
  """
  @spec compile(Flow.t()) :: {:ok, Workflow.t()} | {:error, Exception.t()}
  def compile(%Flow{} = flow) do
    with {:ok, flow} <- Flow.validate(flow),
         {:ok, workflow, _ordered_nodes} <- build(flow, %{}, %{}, nil) do
      {:ok, workflow}
    end
  end

  @doc """
  Compiles and executes a Flow artifact, returning its declared return value.

  Accepted runtime options are `:async` and `:max_concurrency`, which are passed
  through to Runic workflow reaction.
  """
  @spec run(Flow.t(), map(), map(), keyword()) :: {:ok, term()} | {:error, Exception.t()}
  def run(flow, input, context \\ %{}, opts \\ [])

  def run(%Flow{} = flow, input, context, opts) when is_map(input) and is_map(context) do
    runner = self()
    run_ref = make_ref()

    with :ok <- validate_run_opts(opts),
         {:ok, flow} <- Flow.validate(flow),
         :ok <- Flow.check(flow),
         {:ok, workflow, ordered_nodes} <- build(flow, input, context, {runner, run_ref}) do
      final_workflow = Workflow.react_until_satisfied(workflow, input, opts)
      node_errors = drain_node_errors(run_ref, ordered_nodes)

      case node_errors do
        [{_node, error} | _rest] ->
          {:error, error}

        [] ->
          extract_return(flow.return, final_workflow, input, context)
      end
    end
  end

  def run(%Flow{}, _input, _context, _opts) do
    {:error, Error.validation_error("flow input and context must be maps")}
  end

  defp validate_run_opts(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      with :ok <- validate_known_run_opts(opts),
           :ok <- validate_async_opt(Keyword.get(opts, :async, false)),
           :ok <- validate_max_concurrency_opt(Keyword.get(opts, :max_concurrency, 1)) do
        :ok
      end
    else
      {:error, Error.validation_error("run options must be a keyword list")}
    end
  end

  defp validate_run_opts(_opts) do
    {:error, Error.validation_error("run options must be a keyword list")}
  end

  defp validate_known_run_opts(opts) do
    opts
    |> Keyword.keys()
    |> Enum.find(&(&1 not in @run_option_keys))
    |> case do
      nil ->
        :ok

      option ->
        {:error,
         Error.validation_error("unknown run option: #{inspect(option)}", %{option: option})}
    end
  end

  defp validate_async_opt(async) when is_boolean(async), do: :ok

  defp validate_async_opt(_async) do
    {:error, Error.validation_error("async option must be a boolean", %{option: :async})}
  end

  defp validate_max_concurrency_opt(max_concurrency)
       when is_integer(max_concurrency) and max_concurrency > 0,
       do: :ok

  defp validate_max_concurrency_opt(_max_concurrency) do
    {:error,
     Error.validation_error("max_concurrency option must be a positive integer", %{
       option: :max_concurrency
     })}
  end

  defp build(%Flow{} = flow, input, context, collector) do
    nodes_by_name = Map.new(flow.nodes, fn node -> {node.name, node} end)

    node_state =
      %{flow: flow.name, input: input, context: context, results: %{}}
      |> Map.put(@collector_key, collector)

    {workflow, _added, ordered} =
      Enum.reduce(flow.nodes, {Workflow.new(flow.name), MapSet.new(), []}, fn node,
                                                                              {workflow, added,
                                                                               ordered} ->
        add_node(node.name, nodes_by_name, workflow, added, ordered, node_state)
      end)

    {:ok, workflow, ordered}
  end

  defp add_node(name, nodes_by_name, workflow, added, ordered, node_state) do
    if MapSet.member?(added, name) do
      {workflow, added, ordered}
    else
      node = Map.fetch!(nodes_by_name, name)

      {workflow, added, ordered} =
        add_dependencies(node.deps, nodes_by_name, workflow, added, ordered, node_state)

      step =
        Step.new(
          name: node.name,
          work: fn parent_value -> run_node(node, parent_value, node_state) end
        )

      workflow = add_step(workflow, node, step)

      {workflow, MapSet.put(added, name), ordered ++ [node]}
    end
  end

  defp add_dependencies([], _nodes_by_name, workflow, added, ordered, _node_state) do
    {workflow, added, ordered}
  end

  defp add_dependencies(
         [dep | deps],
         nodes_by_name,
         workflow,
         added,
         ordered,
         node_state
       ) do
    {workflow, added, ordered} =
      add_node(dep, nodes_by_name, workflow, added, ordered, node_state)

    add_dependencies(deps, nodes_by_name, workflow, added, ordered, node_state)
  end

  defp add_step(workflow, %{deps: []}, step), do: Workflow.add(workflow, step, validate: :off)

  defp add_step(workflow, %{deps: [dep]}, step) do
    Workflow.add(workflow, step, to: dep, validate: :off)
  end

  defp add_step(workflow, %{deps: deps}, step) do
    Workflow.add(workflow, step, to: deps, validate: :off)
  end

  defp run_node(node, parent_value, node_state) do
    metadata = node_metadata(node, node_state)

    result =
      :telemetry.span([:jido, :flow, :node], metadata, fn ->
        result = run_node_result(node, parent_value, node_state)
        {result, Map.merge(metadata, node_result_metadata(result))}
      end)

    case result do
      {:ok, output} -> output
      {:error, error, state} -> raise_node_error(node, error, state)
    end
  end

  defp run_node_result(node, parent_value, node_state) do
    state = %{node_state | results: dependency_results(node, parent_value)}

    with {:ok, params} <- resolve_expr(node.input, state),
         {:ok, params} <- validate_step_input(node, params),
         {:ok, output} <- call_action(node, params, state.context),
         {:ok, output} <- validate_step_output(node, output) do
      {:ok, output}
    else
      {:error, error} -> {:error, error, state}
    end
  end

  defp node_metadata(node, node_state) do
    %{flow: node_state.flow, node: node.name, action: node.action}
  end

  defp node_result_metadata({:error, error, _state}) do
    %{status: :error, error_type: error_type(error)}
  end

  defp node_result_metadata(_result), do: %{status: :ok}

  defp error_type(error), do: error |> Error.to_map() |> Map.get(:type)

  defp dependency_results(%{deps: []}, _parent_value), do: %{}
  defp dependency_results(%{deps: [dep]}, parent_value), do: %{dep => parent_value}

  defp dependency_results(%{deps: deps}, parent_values) when is_list(parent_values) do
    # Multi-parent nodes are attached with `to: deps`; Runic joins preserve that same order.
    deps
    |> Enum.zip(parent_values)
    |> Map.new()
  end

  defp raise_node_error(node, error, state) do
    record_node_error(node, error, state)
    raise NodeError, node: node.name, error: error
  end

  defp record_node_error(node, error, %{@collector_key => {runner, run_ref}})
       when is_pid(runner) do
    send(runner, {run_ref, :node_error, node.name, error})
  end

  defp record_node_error(_node, _error, _state), do: :ok

  defp drain_node_errors(run_ref, ordered_nodes) do
    node_index =
      ordered_nodes
      |> Enum.with_index()
      |> Map.new(fn {node, index} -> {node.name, index} end)

    run_ref
    |> do_drain_node_errors([])
    |> Enum.sort_by(fn {node, _error} -> Map.fetch!(node_index, node) end)
  end

  defp do_drain_node_errors(run_ref, acc) do
    receive do
      {^run_ref, :node_error, node, error} ->
        do_drain_node_errors(run_ref, [{node, error} | acc])
    after
      0 ->
        acc
    end
  end

  defp call_action(node, params, context) do
    node.action
    |> Exec.invoke_action(params, context)
    |> drop_action_extras()
    |> tag_step_execution_error(node)
  end

  # Extras are instruction-path-only; flow nodes deliberately discard them.
  defp drop_action_extras({:ok, output, _extras}), do: {:ok, output}
  defp drop_action_extras({:error, error}), do: {:error, error}

  defp tag_step_execution_error({:ok, output}, _node), do: {:ok, output}

  defp tag_step_execution_error({:error, error}, node) when is_exception(error) do
    {:error, put_step_details(error, node)}
  end

  defp put_step_details(%{details: details} = error, node) when is_map(details) do
    %{error | details: Map.merge(details, step_details(node))}
  end

  defp put_step_details(error, _node), do: error

  defp step_details(node) do
    %{
      phase: :step_execution,
      node: node.name,
      action: node.action
    }
  end

  defp validate_step_input(node, params) do
    node.action.validate_params(params)
    |> tag_step_validation_error(:step_input, node)
  end

  defp validate_step_output(node, %Output{} = output) do
    output
    |> Output.validate()
    |> tag_step_validation_error(:step_output, node)
  end

  defp validate_step_output(node, output) do
    node.action.validate_output(output)
    |> tag_step_validation_error(:step_output, node)
  end

  defp tag_step_validation_error({:ok, value}, _phase, _node), do: {:ok, value}

  defp tag_step_validation_error({:error, error}, phase, node) when is_exception(error) do
    details =
      error
      |> Map.get(:details, %{})
      |> Map.put(:phase, phase)
      |> Map.put(:node, node.name)
      |> Map.put(:action, node.action)

    {:error, Error.validation_error(Exception.message(error), details)}
  end

  defp tag_step_validation_error({:error, reason}, phase, node) do
    {:error,
     Error.validation_error(to_error_message(reason), %{
       phase: phase,
       node: node.name,
       action: node.action,
       reason: reason
     })}
  end

  defp resolve_expr(%Ref{type: :input, path: path}, state),
    do: {:ok, fetch_path(state.input, path)}

  defp resolve_expr(%Ref{type: :context, path: path}, state),
    do: {:ok, fetch_path(state.context, path)}

  defp resolve_expr(%Ref{type: :value, value: value}, _state), do: {:ok, value}

  defp resolve_expr(%Ref{type: :result, node: node, path: path}, state) do
    {:ok, state.results |> Map.get(node) |> fetch_path(path)}
  end

  defp resolve_expr(%Ref{type: type}, _state) do
    {:error, Error.validation_error("unsupported flow ref type: #{inspect(type)}", %{type: type})}
  end

  defp resolve_expr(%{} = map, state) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case resolve_expr(value, state) do
        {:ok, resolved} -> {:cont, {:ok, Map.put(acc, key, resolved)}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp resolve_expr(list, state) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn value, {:ok, acc} ->
      case resolve_expr(value, state) do
        {:ok, resolved} -> {:cont, {:ok, [resolved | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, error} -> {:error, error}
    end
  end

  defp resolve_expr(value, _state), do: {:ok, value}

  defp extract_return(return_expr, workflow, input, context) do
    result_nodes = return_expr |> Node.collect_result_refs() |> Enum.uniq()
    facts_by_node = Workflow.results(workflow, result_nodes, facts: true, all: true)

    result_nodes
    |> Enum.reduce_while({:ok, %{}}, fn node, {:ok, acc} ->
      case Map.get(facts_by_node, node, []) do
        [] ->
          {:halt, {:error, Error.execution_error("flow execution produced no final state")}}

        facts ->
          value = facts |> List.last() |> Map.fetch!(:value)
          {:cont, {:ok, Map.put(acc, node, value)}}
      end
    end)
    |> case do
      {:ok, results} ->
        resolve_expr(return_expr, %{input: input, context: context, results: results})

      {:error, error} ->
        {:error, error}
    end
  end

  defp fetch_path(value, []), do: value
  defp fetch_path(nil, _path), do: nil

  defp fetch_path(value, [key | rest]) when is_map(value) do
    value
    |> fetch_key(key)
    |> fetch_path(rest)
  end

  defp fetch_path(value, [key | rest]) when is_list(value) and is_integer(key) and key >= 0 do
    value
    |> Enum.at(key)
    |> fetch_path(rest)
  end

  defp fetch_path(_value, _path), do: nil

  defp fetch_key(map, key) do
    cond do
      Map.has_key?(map, key) ->
        Map.get(map, key)

      is_atom(key) and Map.has_key?(map, Atom.to_string(key)) ->
        Map.get(map, Atom.to_string(key))

      true ->
        nil
    end
  end

  defp to_error_message(message) when is_binary(message), do: message
  defp to_error_message(message) when is_atom(message), do: Atom.to_string(message)
  defp to_error_message(message), do: inspect(message)
end
