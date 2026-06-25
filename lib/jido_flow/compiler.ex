defmodule Jido.Flow.Compiler do
  @moduledoc """
  Compiles canonical Flow artifacts into Runic workflows.
  """

  alias Jido.Action.Error
  alias Jido.Action.Output
  alias Jido.Flow
  alias Jido.Flow.Ref
  alias Runic.Workflow
  alias Runic.Workflow.Step

  @type execution_state :: %{
          input: map(),
          context: map(),
          results: map(),
          error: Exception.t() | nil
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
      initial_state = %{input: input, context: context, results: %{}, error: nil}
      final_workflow = Workflow.react_until_satisfied(workflow, initial_state)
      final_state = final_state(final_workflow, List.last(ordered_nodes))

      case final_state do
        %{error: nil} = state -> extract_return(flow.return, state)
        %{error: error} -> {:error, error}
        nil -> {:error, Error.execution_error("flow execution produced no final state")}
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

  defp run_node(_node, %{error: error} = state) when not is_nil(error), do: state

  defp run_node(node, state) do
    with {:ok, params} <- resolve_expr(node.input, state),
         {:ok, params} <- validate_step_input(node, params),
         {:ok, output} <- call_action(node, params, state.context),
         {:ok, output} <- validate_step_output(node, output) do
      put_in(state, [:results, node.name], output)
    else
      {:error, error} -> %{state | error: error}
    end
  end

  defp call_action(node, params, context) do
    case node.action.run(params, context) do
      {:ok, output} ->
        {:ok, output}

      {:ok, output, _extras} ->
        {:ok, output}

      {:error, reason} ->
        {:error, normalize_action_error(node, reason)}

      {:error, reason, _extras} ->
        {:error, normalize_action_error(node, reason)}

      other ->
        {:error,
         Error.execution_error("action returned an unsupported result", %{
           action: node.action,
           node: node.name,
           phase: :step_execution,
           result: other
         })}
    end
  rescue
    exception ->
      {:error,
       Error.execution_error(Exception.message(exception), %{
         action: node.action,
         node: node.name,
         phase: :step_execution,
         exception: exception.__struct__
       })}
  catch
    kind, reason ->
      {:error,
       Error.execution_error("action #{kind}", %{
         action: node.action,
         node: node.name,
         phase: :step_execution,
         reason: reason
       })}
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

  defp resolve_expr(%Ref{type: :value, value: value}, _state), do: {:ok, value}

  defp resolve_expr(%Ref{type: :result, node: node, path: path}, state) do
    {:ok, state.results |> Map.get(node) |> fetch_path(path)}
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

  defp normalize_action_error(_node, error) when is_exception(error), do: error

  defp normalize_action_error(node, reason) do
    Error.execution_error(to_error_message(reason), %{
      action: node.action,
      node: node.name,
      phase: :step_execution,
      reason: reason
    })
  end

  defp to_error_message(message) when is_binary(message), do: message
  defp to_error_message(message) when is_atom(message), do: Atom.to_string(message)
  defp to_error_message(message), do: inspect(message)
end
