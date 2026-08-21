defmodule Jido.Flow.Compiler do
  @moduledoc """
  Compiles canonical Flow artifacts into Runic workflows.
  """

  alias Jido.Action.Error
  alias Jido.Exec
  alias Jido.Flow
  alias Jido.Flow.Choice
  alias Jido.Flow.Condition
  alias Jido.Flow.Element
  alias Jido.Flow.Identity
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
         flow_digest = Identity.semantic_digest(flow),
         {:ok, workflow, _ordered_nodes} <- build(flow, {:inspection, flow_digest}) do
      {:ok, workflow}
    end
  end

  @doc false
  @spec runtime_workflow(Flow.t(), map(), map()) ::
          {:ok, Workflow.t()} | {:error, Exception.t()}
  def runtime_workflow(%Flow{} = flow, input, context)
      when is_map(input) and is_map(context) do
    with {:ok, _flow, workflow, _ordered_nodes} <- prepare_runtime(flow, input, context, nil) do
      {:ok, workflow}
    end
  end

  def runtime_workflow(%Flow{}, _input, _context) do
    {:error, Error.validation_error("flow input and context must be maps")}
  end

  @doc """
  Compiles and executes a Flow artifact, returning its declared return value.

  Accepted runtime options are `:async` and `:max_concurrency`, which are passed
  through to Runic workflow reaction.
  """
  @spec run(Flow.t(), map(), map(), keyword()) :: {:ok, term()} | {:error, Exception.t()}
  def run(flow, input, context \\ %{}, opts \\ [])

  def run(%Flow{} = flow, input, context, opts) when is_map(input) and is_map(context) do
    with :ok <- validate_run_opts(opts),
         {:ok, flow} <- Flow.validate(flow),
         :ok <- Flow.check(flow) do
      execute(flow, input, context, opts)
    end
  end

  def run(%Flow{}, _input, _context, _opts) do
    {:error, Error.validation_error("flow input and context must be maps")}
  end

  @doc false
  @spec run_validated(Flow.t(), map(), map(), keyword()) ::
          {:ok, term()} | {:error, Exception.t()}
  def run_validated(%Flow{} = flow, input, context, opts)
      when is_map(input) and is_map(context) and is_list(opts) do
    execute(flow, input, context, opts)
  end

  defp execute(flow, input, context, opts) do
    runner = self()
    run_ref = make_ref()

    with {:ok, workflow, ordered_nodes} <-
           prepare_validated_runtime(flow, input, context, {runner, run_ref}) do
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

  defp prepare_runtime(flow, input, context, collector) do
    with {:ok, flow} <- Flow.validate(flow),
         :ok <- Flow.check(flow),
         {:ok, workflow, ordered_nodes} <-
           prepare_validated_runtime(flow, input, context, collector) do
      {:ok, flow, workflow, ordered_nodes}
    end
  end

  defp prepare_validated_runtime(flow, input, context, collector) do
    node_state =
      %{flow: flow.name, input: input, context: context, results: %{}}
      |> Map.put(@collector_key, collector)

    build(flow, {:runtime, node_state})
  end

  defp build(%Flow{} = flow, mode) do
    nodes_by_name = Map.new(flow.nodes, fn node -> {Element.name(node), node} end)

    {workflow, _added, ordered} =
      flow.nodes
      |> Flow.canonical_nodes()
      |> Enum.reduce({Workflow.new(flow.name), MapSet.new(), []}, fn node,
                                                                     {workflow, added, ordered} ->
        add_node(Element.name(node), nodes_by_name, workflow, added, ordered, mode)
      end)

    {:ok, workflow, ordered}
  end

  defp add_node(name, nodes_by_name, workflow, added, ordered, mode) do
    if MapSet.member?(added, name) do
      {workflow, added, ordered}
    else
      node = Map.fetch!(nodes_by_name, name)

      {workflow, added, ordered} =
        add_dependencies(Element.deps(node), nodes_by_name, workflow, added, ordered, mode)

      step = build_step(node, mode)

      workflow = add_step(workflow, node, step)

      {workflow, MapSet.put(added, name), ordered ++ [node]}
    end
  end

  defp add_dependencies([], _nodes_by_name, workflow, added, ordered, _mode) do
    {workflow, added, ordered}
  end

  defp add_dependencies(
         [dep | deps],
         nodes_by_name,
         workflow,
         added,
         ordered,
         mode
       ) do
    {workflow, added, ordered} =
      add_node(dep, nodes_by_name, workflow, added, ordered, mode)

    add_dependencies(deps, nodes_by_name, workflow, added, ordered, mode)
  end

  defp build_step(node, {:inspection, flow_digest}) do
    name = Element.name(node)

    Step.new(
      name: name,
      hash: Identity.step_uuid(flow_digest, name),
      work: fn _parent_value -> {:jido_flow_node, 1, name} end
    )
  end

  defp build_step(node, {:runtime, node_state}) do
    Step.new(
      name: node.name,
      work: fn parent_value -> run_node(node, parent_value, node_state) end
    )
  end

  defp add_step(workflow, element, step) do
    case Element.deps(element) do
      [] -> Workflow.add(workflow, step, validate: :off)
      [dep] -> Workflow.add(workflow, step, to: dep, validate: :off)
      deps -> Workflow.add(workflow, step, to: deps, validate: :off)
    end
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
      {:ok, output, _choice_metadata} -> output
      {:error, error, state} -> raise_node_error(node, error, state)
      {:error, error, state, _choice_metadata} -> raise_node_error(node, error, state)
    end
  end

  defp run_node_result(%Choice{} = choice, parent_value, node_state) do
    state = %{node_state | results: dependency_results(choice, parent_value)}

    case select_choice_target(choice, state) do
      {:ok, target} ->
        metadata = %{option: target.name, target: target.action}

        with {:ok, params} <- resolve_expr(target.input, state),
             {:ok, output} <-
               run_resolved_target(
                 target.action,
                 params,
                 state.context,
                 choice_target_owner(choice, target)
               ) do
          {:ok, output, metadata}
        else
          {:error, error} -> {:error, error, state, metadata}
        end

      {:error, error} ->
        {:error, error, state}
    end
  end

  defp run_node_result(node, parent_value, node_state) do
    state = %{node_state | results: dependency_results(node, parent_value)}

    case resolve_expr(node.input, state) do
      {:ok, params} ->
        case run_resolved_node(node, params, state.context) do
          {:ok, output} -> {:ok, output}
          {:error, error} -> {:error, error, state}
        end

      {:error, error} ->
        {:error, error, state}
    end
  end

  defp run_resolved_node(node, params, context) do
    run_resolved_target(node.action, params, context, node_target_owner(node))
  end

  defp flow_module?(action) do
    function_exported?(action, :__jido_flow__, 0)
  end

  defp select_choice_target(%Choice{} = choice, state) do
    choice.options
    |> Enum.reduce_while({:ok, choice.fallback}, fn option, {:ok, _fallback} ->
      case evaluate_condition(option.condition, state, choice.name, option.name) do
        {:ok, true} -> {:halt, {:ok, option}}
        {:ok, false} -> {:cont, {:ok, choice.fallback}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp evaluate_condition(%Condition{operator: :all, operands: conditions}, state, node, option) do
    Enum.reduce_while(conditions, {:ok, true}, fn condition, {:ok, true} ->
      case evaluate_condition(condition, state, node, option) do
        {:ok, true} -> {:cont, {:ok, true}}
        {:ok, false} -> {:halt, {:ok, false}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp evaluate_condition(%Condition{operator: :any, operands: conditions}, state, node, option) do
    Enum.reduce_while(conditions, {:ok, false}, fn condition, {:ok, false} ->
      case evaluate_condition(condition, state, node, option) do
        {:ok, true} -> {:halt, {:ok, true}}
        {:ok, false} -> {:cont, {:ok, false}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp evaluate_condition(%Condition{operator: :not, operands: [condition]}, state, node, option) do
    case evaluate_condition(condition, state, node, option) do
      {:ok, result} -> {:ok, not result}
      {:error, error} -> {:error, error}
    end
  end

  defp evaluate_condition(
         %Condition{operator: operator, operands: [left, right]},
         state,
         node,
         option
       ) do
    with {:ok, left} <- resolve_expr(left, state),
         {:ok, right} <- resolve_expr(right, state) do
      evaluate_comparison(operator, left, right, node, option)
    end
  end

  defp evaluate_comparison(:eq, left, right, _node, _option), do: {:ok, left == right}
  defp evaluate_comparison(:neq, left, right, _node, _option), do: {:ok, left != right}

  defp evaluate_comparison(operator, left, right, node, option)
       when operator in [:lt, :lte, :gt, :gte] do
    if comparable_choice_values?(left, right) do
      result =
        case operator do
          :lt -> left < right
          :lte -> left <= right
          :gt -> left > right
          :gte -> left >= right
        end

      {:ok, result}
    else
      invalid_choice_condition(operator, :invalid_ordering_operands, left, right, node, option)
    end
  end

  defp evaluate_comparison(:in, left, right, node, option) do
    if proper_list?(right) do
      {:ok, Enum.member?(right, left)}
    else
      invalid_choice_condition(:in, :invalid_membership_right_operand, left, right, node, option)
    end
  end

  defp comparable_choice_values?(left, right) do
    (is_number(left) and is_number(right)) or (is_binary(left) and is_binary(right))
  end

  defp proper_list?(value), do: is_list(value) and not List.improper?(value)

  defp invalid_choice_condition(operator, reason, left, right, node, option) do
    {:error,
     Error.execution_error("invalid choice condition operands", %{
       phase: :choice_condition,
       node: node,
       option: option,
       operator: operator,
       reason: reason,
       left_type: choice_value_type(left),
       right_type: choice_value_type(right),
       retry: false
     })}
  end

  defp choice_value_type(value) when is_number(value), do: :number
  defp choice_value_type(value) when is_binary(value), do: :binary
  defp choice_value_type(value) when is_list(value), do: :list
  defp choice_value_type(value) when is_map(value), do: :map
  defp choice_value_type(value) when is_atom(value), do: :atom
  defp choice_value_type(value) when is_tuple(value), do: :tuple
  defp choice_value_type(_value), do: :other

  defp run_resolved_target(action, params, context, owner) do
    if flow_module?(action) do
      action
      |> apply(:flow, [])
      |> Exec.run(params, context)
      |> tag_target_error(:execution, owner)
    else
      with {:ok, params} <- validate_target_input(action, params, owner),
           {:ok, output} <- call_target_action(action, params, context, owner),
           {:ok, output} <- validate_target_output(action, output, owner) do
        {:ok, output}
      end
    end
  end

  defp validate_target_input(action, params, owner) do
    action.validate_params(params)
    |> tag_target_validation_error(:input, owner)
  end

  defp call_target_action(action, params, context, owner) do
    action
    |> Exec.invoke_action(params, context)
    |> drop_action_extras()
    |> tag_target_error(:execution, owner)
  end

  defp validate_target_output(action, output, owner) do
    Exec.validate_action_output(action, output)
    |> tag_target_error(:output, owner)
  end

  defp node_target_owner(node), do: %{kind: :node, node: node}

  defp choice_target_owner(choice, target), do: %{kind: :choice, choice: choice, target: target}

  defp tag_target_error(result, phase, %{kind: :node, node: node}) do
    tag_step_error(result, node_target_phase(phase), node)
  end

  defp tag_target_error(result, phase, %{kind: :choice, choice: choice, target: target}) do
    tag_choice_target_error(result, choice, target, choice_target_phase(phase))
  end

  defp tag_target_validation_error(result, :input, %{kind: :node, node: node}) do
    tag_step_validation_error(result, :step_input, node)
  end

  defp tag_target_validation_error(result, :input, %{
         kind: :choice,
         choice: choice,
         target: target
       }) do
    tag_choice_target_validation_error(result, choice, target, :choice_target_input)
  end

  defp node_target_phase(:execution), do: :step_execution
  defp node_target_phase(:output), do: :step_output

  defp choice_target_phase(:execution), do: :choice_target_execution
  defp choice_target_phase(:output), do: :choice_target_output

  defp node_metadata(%Choice{} = choice, node_state) do
    %{flow: node_state.flow, node: choice.name, kind: :choice}
  end

  defp node_metadata(node, node_state) do
    %{flow: node_state.flow, node: node.name, action: node.action}
  end

  defp node_result_metadata({:error, error, _state}) do
    %{status: :error, error_type: error_type(error)}
  end

  defp node_result_metadata({:error, error, _state, choice_metadata}) do
    Map.merge(%{status: :error, error_type: error_type(error)}, choice_metadata)
  end

  defp node_result_metadata({:ok, _output, choice_metadata}) do
    Map.merge(%{status: :ok}, choice_metadata)
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

  # Extras are instruction-path-only; flow nodes deliberately discard them.
  defp drop_action_extras({:ok, output, _extras}), do: {:ok, output}
  defp drop_action_extras({:error, error}), do: {:error, error}

  defp tag_step_error({:ok, output}, _phase, _node), do: {:ok, output}

  defp tag_step_error({:error, error}, phase, node) when is_exception(error) do
    {:error, put_step_details(error, phase, node)}
  end

  defp tag_step_error({:error, error}, _phase, _node), do: {:error, error}

  defp put_step_details(%{details: details} = error, phase, node) when is_map(details) do
    %{
      error
      | details: Map.merge(details, %{phase: phase, node: node.name, action: node.action})
    }
  end

  defp put_step_details(error, _phase, _node), do: error

  defp tag_choice_target_error({:ok, output}, _choice, _target, _phase), do: {:ok, output}

  defp tag_choice_target_error({:error, error}, choice, target, phase) when is_exception(error) do
    {:error, put_choice_target_details(error, choice, target, phase)}
  end

  defp tag_choice_target_error({:error, error}, _choice, _target, _phase), do: {:error, error}

  defp tag_choice_target_validation_error({:ok, value}, _choice, _target, _phase),
    do: {:ok, value}

  defp tag_choice_target_validation_error({:error, error}, choice, target, phase)
       when is_exception(error) do
    details =
      error
      |> Map.get(:details, %{})
      |> choice_target_details(choice, target, phase)

    {:error, Error.validation_error(Exception.message(error), details)}
  end

  defp tag_choice_target_validation_error({:error, reason}, choice, target, phase) do
    {:error,
     Error.validation_error(
       to_error_message(reason),
       choice_target_details(%{reason: reason}, choice, target, phase)
     )}
  end

  defp put_choice_target_details(%{details: details} = error, choice, target, phase)
       when is_map(details) do
    %{error | details: choice_target_details(details, choice, target, phase)}
  end

  defp put_choice_target_details(error, _choice, _target, _phase), do: error

  defp choice_target_details(details, choice, target, phase) do
    Map.merge(details, %{
      phase: phase,
      node: choice.name,
      option: target.name,
      target: target.action
    })
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
