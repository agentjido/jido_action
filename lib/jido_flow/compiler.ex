defmodule Jido.Flow.Compiler do
  @moduledoc """
  Compiles canonical Flow artifacts into Runic workflows.
  """

  alias Jido.Action.Error
  alias Jido.Action.Output
  alias Jido.Exec
  alias Jido.Flow
  alias Jido.Flow.NodeError
  alias Jido.Flow.Ref
  alias Runic.Workflow
  alias Runic.Workflow.Step

  @collector_key :__jido_flow_error_collector__

  @type execution_state :: %{
          input: map(),
          context: map(),
          results: map()
        }

  @doc """
  Compiles a Flow artifact into a Runic workflow.
  """
  @spec compile(Flow.t()) :: {:ok, Workflow.t()} | {:error, Exception.t()}
  def compile(%Flow{} = flow) do
    with {:ok, ordered_nodes} <- topological_order(flow.nodes) do
      workflow =
        ordered_nodes
        |> Enum.reduce({Workflow.new(flow.name), nil}, fn node, {workflow, previous_name} ->
          step = Step.new(name: node.name, work: fn state -> run_node(node, state) end)

          workflow =
            if previous_name do
              Workflow.add(workflow, step, to: previous_name, validate: :off)
            else
              Workflow.add(workflow, step, validate: :off)
            end

          {workflow, node.name}
        end)
        |> elem(0)

      {:ok, workflow}
    end
  end

  @doc """
  Compiles and executes a Flow artifact, returning its declared return value.
  """
  @spec run(Flow.t(), map(), map()) :: {:ok, term()} | {:error, Exception.t()}
  def run(flow, input, context \\ %{})

  def run(%Flow{} = flow, input, context) when is_map(input) and is_map(context) do
    with {:ok, ordered_nodes} <- topological_order(flow.nodes),
         {:ok, workflow} <- compile(flow) do
      runner = self()
      run_ref = make_ref()

      initial_state =
        %{input: input, context: context, results: %{}}
        |> Map.put(@collector_key, {runner, run_ref})

      final_workflow = Workflow.react_until_satisfied(workflow, initial_state)
      node_errors = drain_node_errors(run_ref, ordered_nodes)

      case node_errors do
        [{_node, error} | _rest] ->
          {:error, error}

        [] ->
          case final_state(final_workflow, List.last(ordered_nodes)) do
            nil -> {:error, Error.execution_error("flow execution produced no final state")}
            state -> extract_return(flow.return, state)
          end
      end
    end
  end

  def run(%Flow{}, _input, _context) do
    {:error, Error.validation_error("flow input and context must be maps")}
  end

  defp topological_order(nodes) do
    do_topological_order(nodes, MapSet.new(), [])
  end

  defp do_topological_order([], _done, ordered), do: {:ok, Enum.reverse(ordered)}

  defp do_topological_order(remaining, done, ordered) do
    case Enum.find(remaining, &deps_satisfied?(&1, done)) do
      nil ->
        {:error,
         Error.config_error("dependency graph cannot be topologically ordered", %{
           nodes: Enum.map(remaining, & &1.name)
         })}

      node ->
        remaining = List.delete(remaining, node)
        do_topological_order(remaining, MapSet.put(done, node.name), [node | ordered])
    end
  end

  defp deps_satisfied?(node, done) do
    Enum.all?(node.deps, &MapSet.member?(done, &1))
  end

  defp run_node(node, state) do
    with {:ok, params} <- resolve_expr(node.input, state),
         {:ok, params} <- validate_step_input(node, params),
         {:ok, output} <- call_action(node, params, state.context),
         {:ok, output} <- validate_step_output(node, output) do
      put_in(state, [:results, node.name], output)
    else
      {:error, error} -> raise_node_error(node, error, state)
    end
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

  defp extract_return(%Ref{} = ref, state) do
    with {:ok, value} <- resolve_expr(ref, state) do
      {:ok, value}
    end
  end

  defp final_state(_workflow, nil), do: nil

  defp final_state(workflow, node) do
    workflow
    |> Workflow.results([node.name])
    |> Map.get(node.name)
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
