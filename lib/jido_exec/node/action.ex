defmodule Jido.Exec.Node.Action do
  @moduledoc false

  alias Jido.Action.Error
  alias Jido.Exec.{Frame, Portable, ValueResolver}
  alias Jido.Exec.Node.Loop
  alias Jido.Instruction
  alias Runic.Identity

  @enforce_keys [:id, :name, :hash, :instruction, :inputs, :outputs]
  defstruct [:id, :name, :hash, :instruction, :inputs, :outputs]

  @type t :: %__MODULE__{
          id: term(),
          name: atom() | String.t(),
          hash: Identity.t(),
          instruction: Instruction.t(),
          inputs: keyword(),
          outputs: keyword()
        }

  @spec new(Instruction.t(), keyword()) :: t()
  def new(instruction, opts \\ [])

  def new(%Instruction{kind: :action, target: action} = instruction, opts) do
    opts = Keyword.validate!(opts, [:id, :name])

    case Instruction.validate_resolved(instruction) do
      :ok -> :ok
      {:error, error} -> raise error
    end

    name = Keyword.get_lazy(opts, :name, fn -> action_name(action) end)
    id = Keyword.get(opts, :id, name)

    hash =
      Identity.digest(:component_definition, %{
        kind: "jido_action",
        version: 1,
        id: identity_value(id),
        target: Atom.to_string(action)
      })

    %__MODULE__{
      id: id,
      name: name,
      hash: hash,
      instruction: instruction,
      inputs: ports(:input, action),
      outputs: ports(:output, action)
    }
  end

  def new(%Instruction{} = instruction, _opts) do
    raise ArgumentError,
          "expected an Action Instruction, got: #{inspect(instruction.kind)}"
  end

  @spec action_metadata(t()) :: map() | nil
  def action_metadata(%__MODULE__{instruction: %Instruction{target: action}}) do
    if function_exported?(action, :to_json, 0), do: action.to_json()
  end

  @doc false
  @spec execute(t(), term(), map()) :: {:ok, term(), [term()]} | {:error, Exception.t()}
  def execute(%__MODULE__{instruction: instruction}, input, run_context) do
    {durable?, run_context} = Map.pop(run_context, :__jido_exec_durable__, false)
    flow_metadata = Map.get(instruction.metadata, :jido_flow)

    result =
      case flow_metadata do
        %{mode: {:loop, %Loop{} = loop}} ->
          Loop.run_action(loop, instruction, input, run_context, &execute_action/3)

        %{mode: {:dispatch, phase, dispatch}, params: params} ->
          execute_dispatch(instruction, phase, dispatch, params, input, run_context)

        %{component: component, mode: {:map, on_error}, params: params} ->
          execute_map_component(instruction, component, params, on_error, input, run_context)

        %{component: component, params: params} ->
          execute_flow_component(instruction, component, params, input, run_context)

        nil ->
          params = merge_params(instruction.params, input)
          execute_action(instruction, params, run_context)
      end

    result
    |> validate_durable_result(durable?)
    |> tag_flow_error(flow_metadata, input)
  end

  defp validate_durable_result({:ok, value, effects} = result, true) do
    with :ok <- Portable.validate(value, :output),
         :ok <- Portable.validate(effects, :effects) do
      result
    end
  end

  defp validate_durable_result(result, _durable?), do: result

  defp execute_map_component(
         _instruction,
         component,
         _params,
         on_error,
         {:jido_map_empty, frame, component},
         _run_context
       ) do
    {:ok, {:jido_map_result, frame, component, 0, on_error, :empty}, []}
  end

  defp execute_map_component(
         instruction,
         component,
         params,
         on_error,
         {:jido_map_item, frame, item, index, item_id},
         run_context
       ) do
    resolver_state =
      frame
      |> Frame.resolver_state(run_context)
      |> Map.merge(%{item: item, item_index: index, item_id: item_id})

    with {:ok, resolved_params} <- ValueResolver.resolve(params, resolver_state) do
      case execute_action(instruction, resolved_params, run_context) do
        {:ok, output, effects} ->
          {:ok, {:jido_map_result, frame, component, index, on_error, {:ok, output, effects}}, []}

        {:error, error} when on_error == :collect_errors ->
          {:ok,
           {:jido_map_result, frame, component, index, on_error, {:error, portable_error(error)}},
           []}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  defp execute_flow_component(instruction, component, params, input, run_context) do
    input = unwrap_flow_input(input)

    with {:ok, frame} <- Frame.merge(input),
         {:ok, resolved_params} <-
           ValueResolver.resolve(params, Frame.resolver_state(frame, run_context)),
         {:ok, output, effects} <- execute_action(instruction, resolved_params, run_context) do
      {:ok, Frame.put_result(frame, component, output, effects), []}
    end
  end

  defp execute_dispatch(instruction, :decision, dispatch, _params, input, run_context) do
    with {:ok, frame} <- Frame.merge(input),
         {:ok, params} <-
           ValueResolver.resolve(
             dispatch.decision_params,
             Frame.resolver_state(frame, run_context)
           ),
         {:ok, output, effects} <- execute_action(instruction, params, run_context) do
      {:ok, {:jido_dispatch_decision, frame, dispatch.component, output, effects}, []}
    end
  end

  defp execute_dispatch(
         instruction,
         :expander,
         _dispatch,
         _params,
         {:jido_dispatch_decision, frame, component, decision, effects},
         run_context
       ) do
    context = Map.merge(instruction.context, run_context)
    action = instruction.target

    with {:ok, params} <- call_validator(action, :validate_params, decision, :input) do
      case safe_apply(action, :run, [params, context], :run) do
        {:ok, {:ok, output}} ->
          dispatch_output(instruction, frame, component, output, effects, [], run_context)

        {:ok, {:ok, output, requests}} when is_list(requests) ->
          dispatch_output(
            instruction,
            frame,
            component,
            output,
            effects,
            requests,
            run_context
          )

        {:ok, {:continue, input, target}} ->
          {:ok, {:jido_dispatch_continue, frame, component, input, target, effects}, []}

        {:ok, {:error, reason}} ->
          {:error, normalize_action_error(action, reason)}

        {:ok, other} ->
          {:error,
           Error.execution_error("Action returned an invalid value", %{
             action: action,
             phase: :run,
             return: other,
             reason: :invalid_return
           })}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  defp execute_dispatch(
         instruction,
         :target,
         dispatch,
         params,
         frame,
         run_context
       ) do
    with {:ok, frame} <- Frame.merge(frame),
         effects = Frame.effects_for(frame, dispatch.component),
         {:ok, output, requests} <- execute_action(instruction, params, run_context) do
      {:ok,
       {:jido_dispatch_target_result, frame, dispatch.component, output, effects ++ requests}, []}
    end
  end

  defp dispatch_output(instruction, frame, component, output, effects, requests, _run_context) do
    action = instruction.target

    with {:ok, output} <- call_validator(action, :validate_output, output, :output) do
      {:ok, {:jido_dispatch_finish, frame, component, output, effects ++ requests}, []}
    end
  end

  defp unwrap_flow_input({:jido_choice_branch, true, frame}), do: frame
  defp unwrap_flow_input({:jido_choice_selection, _option, frame}), do: frame
  defp unwrap_flow_input(input), do: input

  defp execute_action(instruction, params, run_context) do
    context = Map.merge(instruction.context, run_context)
    action = instruction.target

    with {:ok, validated_params} <- call_validator(action, :validate_params, params, :input),
         {:ok, output, effects} <- call_action(action, validated_params, context),
         {:ok, validated_output} <- call_validator(action, :validate_output, output, :output) do
      {:ok, validated_output, effects}
    end
  end

  defp call_validator(action, callback, value, phase) do
    case safe_apply(action, callback, [value], phase) do
      {:ok, {:ok, validated}} ->
        {:ok, validated}

      {:ok, {:error, error}} when is_exception(error) ->
        {:error, error}

      {:ok, {:error, reason}} ->
        {:error,
         Error.validation_error(validation_message(phase), %{
           action: action,
           phase: phase,
           reason: reason
         })}

      {:ok, other} ->
        {:error,
         Error.internal_error("Action validator returned an invalid value", %{
           action: action,
           phase: phase,
           return: other,
           reason: :invalid_validator_return
         })}

      {:error, error} ->
        {:error, error}
    end
  end

  defp call_action(action, params, context) do
    case safe_apply(action, :run, [params, context], :run) do
      {:ok, {:ok, output}} ->
        {:ok, output, []}

      {:ok, {:ok, output, effects}} when is_list(effects) ->
        if List.improper?(effects) do
          invalid_effects(action, effects)
        else
          {:ok, output, effects}
        end

      {:ok, {:ok, _output, effects}} ->
        invalid_effects(action, effects)

      {:ok, {:error, reason}} ->
        {:error, normalize_action_error(action, reason)}

      {:ok, {:error, reason, _effects}} ->
        {:error, normalize_action_error(action, reason)}

      {:ok, {:continue, _input, _target} = continuation} ->
        {:error,
         Error.execution_error("Action continuations are not supported by Runic execution", %{
           action: action,
           phase: :run,
           return: continuation,
           reason: :unsupported_continuation
         })}

      {:ok, other} ->
        {:error,
         Error.execution_error("Action returned an invalid value", %{
           action: action,
           phase: :run,
           return: other,
           reason: :invalid_return
         })}

      {:error, error} ->
        {:error, error}
    end
  end

  defp safe_apply(action, callback, args, phase) do
    {:ok, apply(action, callback, args)}
  rescue
    exception ->
      stacktrace = __STACKTRACE__

      error =
        Error.execution_error(Exception.message(exception), %{
          action: action,
          phase: phase,
          exception: exception.__struct__,
          stacktrace: stacktrace
        })

      {:error, %{error | stacktrace: %Splode.Stacktrace{stacktrace: stacktrace}}}
  catch
    kind, reason ->
      stacktrace = __STACKTRACE__

      error =
        Error.execution_error("Action #{phase} #{kind}", %{
          action: action,
          phase: phase,
          kind: kind,
          reason: reason,
          stacktrace: stacktrace
        })

      {:error, %{error | stacktrace: %Splode.Stacktrace{stacktrace: stacktrace}}}
  end

  defp normalize_action_error(_action, error) when is_exception(error), do: error

  defp normalize_action_error(action, reason) do
    Error.execution_error(error_message(reason), %{action: action, phase: :run, reason: reason})
  end

  defp invalid_effects(action, effects) do
    {:error,
     Error.execution_error("Action returned an invalid effects list", %{
       action: action,
       phase: :run,
       effects: effects,
       reason: :invalid_effects
     })}
  end

  defp merge_params(params, input) when is_map(params) and is_map(input),
    do: Map.merge(params, input)

  defp merge_params(params, input) when is_map(params), do: Map.put(params, :input, input)
  defp merge_params(_params, input) when is_map(input), do: input
  defp merge_params(_params, input), do: %{input: input}

  defp ports(:input, action) do
    [in: [type: :any, doc: "Action input", schema: portable_schema(action, "input_schema")]]
  end

  defp ports(:output, action) do
    [out: [type: :any, doc: "Action output", schema: portable_schema(action, "output_schema")]]
  end

  defp portable_schema(action, key) do
    if function_exported?(action, :to_json, 0) do
      action |> apply(:to_json, []) |> Map.get(key, %{})
    else
      %{}
    end
  end

  defp action_name(action) do
    if function_exported?(action, :name, 0), do: action.name(), else: Atom.to_string(action)
  end

  defp identity_value(value) when is_atom(value), do: Atom.to_string(value)
  defp identity_value(value) when is_binary(value), do: value
  defp identity_value(value), do: inspect(value)

  defp validation_message(:input), do: "Action input validation failed"
  defp validation_message(:output), do: "Action output validation failed"

  defp error_message(message) when is_binary(message), do: message
  defp error_message(message) when is_atom(message), do: Atom.to_string(message)
  defp error_message(message), do: inspect(message)

  defp portable_error(error) when is_exception(error) do
    %{type: error.__struct__ |> Atom.to_string(), message: Exception.message(error)}
  end

  defp portable_error(error), do: %{type: "error", message: error_message(error)}

  defp tag_flow_error({:error, %{details: details} = error}, metadata, input)
       when is_map(metadata) and is_map(details) do
    component = Map.get(metadata, :component)

    flow_details =
      %{node: component, node_path: Map.get(metadata, :node_path, [component])}
      |> Map.merge(flow_position(input))
      |> maybe_put(:source, Map.get(metadata, :location))

    {:error, %{error | details: Map.merge(details, flow_details)}}
  end

  defp tag_flow_error(result, _metadata, _input), do: result

  defp flow_position({:jido_map_item, _frame, _item, index, item_id}),
    do: %{item_index: index, item_id: item_id}

  defp flow_position({:jido_reduce, _status, _frame, _component, items, index, _acc, _effects}) do
    item = Enum.at(items, index)
    %{item_index: index, item_id: stable_item_id(index, item)}
  end

  defp flow_position(
         {:jido_iterate, _status, _frame, _component, _state, completed, _body, _effects}
       ),
       do: %{iteration_index: completed, state_revision: completed}

  defp flow_position(_input), do: %{}

  defp stable_item_id(index, item) do
    digest =
      {index, item}
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    digest
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

defimpl Runic.Identity.Projectable, for: Jido.Exec.Node.Action do
  def identity_document(node) do
    %{kind: :jido_action, version: 1, id: inspect(node.id)}
  end
end

defimpl Runic.Workflow.Invokable, for: Jido.Exec.Node.Action do
  alias Jido.Exec.Node.Action
  alias Runic.Workflow

  alias Runic.Workflow.{CausalContext, Fact, HookRunner, Runnable}
  alias Runic.Workflow.Events.{ActivationConsumed, FactProduced, MapReduceTracked}

  def match_or_execute(_node), do: :execute

  def invoke(%Action{} = node, workflow, fact) do
    {:ok, runnable} = prepare(node, workflow, fact)
    executed = execute(node, runnable)
    Workflow.apply_runnable(workflow, executed)
  end

  def prepare(%Action{} = node, %Workflow{} = workflow, %Fact{} = fact) do
    context =
      CausalContext.new(
        node_hash: node.hash,
        input_fact: fact,
        ancestry_depth: Workflow.ancestry_depth(workflow, fact),
        hooks: Workflow.get_hooks(workflow, node.hash),
        run_context: Workflow.get_run_context(workflow, node.name)
      )

    {:ok, Runnable.new(node, fact, context)}
  end

  def execute(%Action{} = node, %Runnable{input_fact: fact, context: context} = runnable) do
    with {:ok, before_apply_fns} <- HookRunner.run_before(context, node, fact),
         {:ok, value, effects} <- Action.execute(node, fact.value, context.run_context) do
      result_fact =
        Fact.new(
          value: value,
          ancestry: {node.hash, fact.hash},
          meta: append_effects(fact.meta, effects)
        )

      case HookRunner.run_after(context, node, fact, result_fact) do
        {:ok, after_apply_fns} ->
          events =
            [
              FactProduced.new(result_fact,
                producer_label: :produced,
                weight: context.ancestry_depth + 1
              ),
              %ActivationConsumed{
                fact_hash: fact.hash,
                node_hash: node.hash,
                from_label: :runnable
              }
            ] ++ map_reduce_events(node, fact, result_fact)

          Runnable.complete(
            runnable,
            result_fact,
            events,
            before_apply_fns ++ after_apply_fns
          )

        {:error, reason} ->
          Runnable.fail(runnable, {:hook_error, reason})
      end
    else
      {:error, reason} -> Runnable.fail(runnable, reason)
    end
  end

  defp append_effects(meta, effects) do
    jido = Map.get(meta, :jido, %{})
    prior = Map.get(jido, :effects, [])
    Map.put(meta, :jido, Map.put(jido, :effects, prior ++ effects))
  end

  defp map_reduce_events(
         %Action{instruction: %{metadata: %{jido_flow: %{mode: {:map, _}}}}} = node,
         %Fact{
           hash: fan_out_fact_hash,
           ancestry: {fan_out_hash, source_fact_hash},
           causal_ancestry: %{output_port: :fan_out}
         },
         %Fact{hash: result_fact_hash}
       ) do
    [
      %MapReduceTracked{
        source_fact_hash: source_fact_hash,
        fan_out_hash: fan_out_hash,
        fan_out_fact_hash: fan_out_fact_hash,
        step_hash: node.hash,
        result_fact_hash: result_fact_hash
      }
    ]
  end

  defp map_reduce_events(_node, _fact, _result_fact), do: []
end

defimpl Runic.Component, for: Jido.Exec.Node.Action do
  alias Jido.Exec.Node.Action
  alias Runic.Workflow

  def connectable?(_node, _other), do: true

  def connect(%Action{} = node, to, workflow) when is_list(to) do
    join = to |> Enum.map(& &1.hash) |> Runic.Workflow.Join.new()

    workflow = Enum.reduce(to, workflow, &Workflow.add_step(&2, &1, join))

    workflow
    |> Workflow.add_step(join, node)
    |> register(node)
  end

  def connect(%Action{} = node, to, workflow) do
    workflow
    |> Workflow.add_step(to, node)
    |> register(node)
  end

  def source(%Action{} = node) do
    instruction = :erlang.term_to_binary(node.instruction)
    id = :erlang.term_to_binary(node.id)

    quote do
      Jido.Exec.Node.Action.new(
        :erlang.binary_to_term(unquote(instruction)),
        id: :erlang.binary_to_term(unquote(id)),
        name: unquote(node.name)
      )
    end
  end

  def hash(%Action{hash: hash}), do: hash
  def inputs(%Action{inputs: inputs}), do: inputs
  def outputs(%Action{outputs: outputs}), do: outputs

  defp register(workflow, node) do
    workflow
    |> Workflow.draw_connection(node, node, :component_of, properties: %{kind: :action})
    |> Workflow.register_component(node)
  end
end

defimpl Runic.Transmutable, for: Jido.Exec.Node.Action do
  alias Runic.Workflow

  def transmute(node), do: to_workflow(node)

  def to_workflow(node) do
    Workflow.new(
      name: to_string(node.name),
      output_ports: [result: [type: :any, from: node.name]]
    )
    |> Workflow.add(node)
  end

  def to_component(node), do: node
end
