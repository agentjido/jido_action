defmodule Jido.Exec.Flow.Compiler do
  @moduledoc false

  alias Jido.Exec.Transition
  alias Jido.Flow
  alias Jido.Flow.Choice
  alias Jido.Exec.Flow.Compiled
  alias Jido.Flow.Dispatch
  alias Jido.Flow.Error
  alias Jido.Exec.Flow.Choice, as: ChoiceRuntime
  alias Jido.Exec.Flow.Collection
  alias Jido.Exec.Flow.Frame
  alias Jido.Exec.Flow.ValueResolver
  alias Jido.Exec.Flow.Payload
  alias Jido.Exec.Flow.Iterator, as: IterateRuntime
  alias Jido.Exec.Flow.Compiler.SourceMap
  alias Jido.Exec.Flow.Target
  alias Jido.Exec.Flow.Validator
  alias Jido.Flow.Component
  alias Jido.Flow.Graph
  alias Jido.Flow.Identity
  alias Jido.Flow.Iterate
  alias Jido.Flow.Map, as: FlowMap
  alias Jido.Flow.Reduce, as: FlowReduce
  alias Jido.Flow.Step, as: FlowStep
  alias Jido.Flow.Subflow
  alias Jido.Flow.Validation
  alias Runic.Workflow

  alias Runic.Workflow.{
    Components,
    FanIn,
    FanOut,
    Step
  }

  alias Runic.Workflow.Map, as: RunicMap
  alias Runic.Workflow.Reduce, as: RunicReduce

  @compiler_version 7
  @runtime_ref %{
    kind: :context,
    target: :jido,
    context_key: :jido,
    field_path: []
  }

  @doc false
  @spec compile(Flow.t(), keyword() | Compiled.source_map()) ::
          {:ok, Compiled.t()} | {:error, Exception.t()}
  def compile(%Flow{} = flow, opts \\ []) do
    with {:ok, _flow, compiled} <- prepare(flow, opts) do
      {:ok, compiled}
    end
  end

  @doc false
  @spec prepare(Flow.t(), keyword() | Compiled.source_map()) ::
          {:ok, Flow.t(), Compiled.t()} | {:error, Exception.t()}
  def prepare(%Flow{} = flow, opts \\ []) do
    prepare(flow, opts, [])
  end

  @doc false
  @spec prepare(Flow.t(), keyword() | Compiled.source_map(), [module()]) ::
          {:ok, Flow.t(), Compiled.t()} | {:error, Exception.t()}
  def prepare(%Flow{} = flow, opts, module_stack) when is_list(module_stack) do
    with {:ok, source_map} <- SourceMap.prepare(opts, module_stack),
         {:ok, attrs, subflows} <-
           Validation.prepare_executable(Map.from_struct(flow), module_stack),
         flow = struct!(Flow, attrs),
         {:ok, compiled} <- compile_prepared(flow, source_map, subflows) do
      {:ok, flow, compiled}
    end
  end

  defp compile_prepared(flow, source_map, subflows) do
    try do
      state = compile_flow(flow, [], source_map, nil, subflows)

      digest_data = %{
        compiler: @compiler_version,
        flow: state.semantic_digest,
        children: Enum.sort(state.child_digests)
      }

      {:ok,
       %Compiled{
         workflow: state.workflow,
         component_index: state.component_index,
         work_index: state.work_index,
         output: flow.output,
         source_map: state.source_map,
         semantic_digest: digest_data.flow,
         compilation_digest: digest(digest_data)
       }}
    rescue
      error -> {:error, normalize_compile_error(error)}
    catch
      kind, reason ->
        {:error,
         Error.internal_error("flow compilation failed", %{
           phase: :flow_compilation,
           kind: kind,
           reason: reason
         })}
    end
  end

  defp compile_flow(flow, namespace, source_map, root_parent, subflows) do
    workflow_name = scoped(namespace, flow.name)

    workflow =
      case root_parent do
        nil -> Workflow.new(name: workflow_name)
        %Step{} = parent -> Workflow.new(name: workflow_name) |> Workflow.add(parent)
      end

    ordered_components = Graph.canonical_components(flow.components)

    initial = %{
      semantic_digest: Identity.semantic_digest(flow, ordered_components),
      workflow: workflow,
      flow: flow,
      namespace: namespace,
      root_parent: root_parent,
      outputs: %{},
      component_index: %{},
      work_index: %{},
      source_map: source_map,
      child_digests: [],
      subflows: subflows
    }

    Enum.reduce(ordered_components, initial, fn component, state ->
      next = add_component(%{component | meta: %{}}, state)

      update_in(
        next.component_index[component.name],
        &Map.put(&1, :effect_order, map_size(state.component_index))
      )
    end)
  end

  defp add_component(%FlowStep{} = component, state) do
    namespace = state.namespace

    step =
      runtime_step(state, component.name, :step, fn parent, runtime ->
        local = component_state(component, parent, runtime)

        local
        |> resolve_and_run(
          component.params,
          Target.at(Target.step(component), namespace)
        )
        |> wrap_result()
      end)

    add_authored_output(state, component, step, step)
  end

  defp add_component(%Choice{} = component, state) do
    namespace = state.namespace

    step =
      runtime_step(state, component.name, :choice, fn parent, runtime ->
        local = component_state(component, parent, runtime)
        result = ChoiceRuntime.run(component, Map.put(local, :namespace, namespace))
        {output, effects} = unwrap_component_result(result)
        Frame.value(local.input_frame, output, effects)
      end)

    add_authored_output(state, component, step, step)
  end

  defp add_component(%Iterate{} = component, state) do
    namespace = state.namespace

    step =
      runtime_step(state, component.name, :iterate, fn parent, runtime ->
        local = component_state(component, parent, runtime)
        result = IterateRuntime.run(component, Map.put(local, :namespace, namespace))
        {output, effects} = unwrap_component_result(result)
        Frame.value(local.input_frame, output, effects)
      end)

    add_authored_output(state, component, step, step)
  end

  defp add_component(%Dispatch{} = component, state) do
    step =
      runtime_step(state, component.name, :dispatch, fn parent, runtime ->
        local = component_state(component, parent, runtime)
        run_dispatch(component, local)
      end)

    add_authored_output(state, component, step, step)
  end

  defp add_component(%FlowMap{} = component, state), do: add_map(component, state)
  defp add_component(%FlowReduce{} = component, state), do: add_reduce(component, state)
  defp add_component(%Subflow{} = component, state), do: add_subflow(component, state)

  defp add_authored_output(state, component, native_component, output_node) do
    workflow = add_with_dependencies(state, component, native_component)
    output_name = output_node.name
    state = index_work(state, component, [{output_node, :execute}])

    %{
      state
      | workflow: workflow,
        outputs: Map.put(state.outputs, component.name, output_node),
        component_index:
          Map.put(state.component_index, component.name, %{
            kind: Component.kind(component),
            component: native_component,
            output: output_name,
            output_port: :out
          })
    }
  end

  defp add_map(map, state) do
    resolver_name = support_name(state, map.name, "map-input")
    namespace = state.namespace

    resolver =
      runtime_step_named(resolver_name, state, :map_input, fn parent, runtime ->
        local = component_state(map, parent, runtime)

        Collection.map_input(map, Map.put(local, :namespace, namespace))
      end)

    workflow = add_with_dependencies(state, map, resolver)
    native_name = support_name(state, map.name, "map")
    item_step = map_item_step(state, map, native_name)
    fan_out = %FanOut{hash: stable_hash({native_name, :fan_out}), name: native_name}

    pipeline =
      Workflow.new(name: native_name)
      |> Workflow.add_step(fan_out)
      |> Workflow.add_step(fan_out, item_step)

    native_map = %RunicMap{
      name: native_name,
      hash: stable_hash({native_name, :map}),
      pipeline: pipeline,
      components: nil,
      closure: nil,
      inputs: nil,
      outputs: nil
    }

    workflow = Workflow.add(workflow, native_map, to: resolver)
    collector_name = support_name(state, map.name, "map-collector")

    collector = %RunicReduce{
      name: collector_name,
      hash: stable_hash({collector_name, :reduce}),
      fan_in: %FanIn{
        name: collector_name,
        hash: stable_hash({collector_name, :fan_in}),
        map: native_name,
        init: fn -> [] end,
        reducer: fn token, tokens -> [token | tokens] end,
        meta_refs: []
      },
      closure: nil,
      inputs: nil,
      outputs: nil
    }

    workflow = Workflow.add(workflow, collector, to: native_map)

    output_step =
      data_step(
        name: output_name(state, map.name),
        hash: stable_hash({state.namespace, map.name, :map_output}),
        work: fn tokens -> Collection.collect_map_tokens(map, tokens) end
      )

    workflow = Workflow.add(workflow, output_step, to: collector.fan_in)

    state =
      index_work(state, map, [
        {resolver, :input},
        {native_map, :fan_out},
        {fan_out, :fan_out},
        {item_step, :map_item},
        {collector.fan_in, :fan_in},
        {output_step, :output}
      ])

    index = %{
      kind: :map,
      component: native_map,
      collector: collector,
      output: output_step.name,
      output_port: :out
    }

    %{
      state
      | workflow: workflow,
        outputs: Map.put(state.outputs, map.name, output_step),
        component_index: Map.put(state.component_index, map.name, index)
    }
  end

  defp map_item_step(state, map, native_name) do
    name = "#{native_name}/item"
    namespace = state.namespace

    runtime_step_named(name, state, :map_item, fn token, runtime ->
      Collection.map_item(map, namespace, token, runtime)
    end)
  end

  defp add_reduce(reduce, state) do
    resolver_name = support_name(state, reduce.name, "reduce-input")
    namespace = state.namespace

    resolver =
      runtime_step_named(resolver_name, state, :reduce_input, fn parent, runtime ->
        local = component_state(reduce, parent, runtime)

        Collection.reduce_input(reduce, Map.put(local, :namespace, namespace))
      end)

    workflow = add_with_dependencies(state, reduce, resolver)
    {native_reduce, output_step} = reduce_components(state, reduce)
    workflow = Workflow.add(workflow, native_reduce, to: resolver)
    workflow = Workflow.add(workflow, output_step, to: native_reduce.fan_in)

    state =
      index_work(state, reduce, [
        {resolver, :input},
        {native_reduce.fan_in, :fan_in},
        {output_step, :output}
      ])

    put_reduce_output(state, reduce, workflow, native_reduce, output_step)
  end

  defp reduce_components(state, reduce) do
    native_name = support_name(state, reduce.name, "reduce")

    native_reduce = %RunicReduce{
      name: native_name,
      hash: stable_hash({native_name, :reduce}),
      fan_in: %FanIn{
        name: native_name,
        hash: stable_hash({native_name, :fan_in}),
        map: nil,
        init: fn ->
          Payload.new(%{
            initialized: false,
            accumulator: nil,
            input: nil,
            error: nil,
            effects: []
          })
        end,
        reducer: Collection.reduce_fun(reduce, state.namespace),
        meta_refs: [@runtime_ref]
      },
      closure: nil,
      inputs: nil,
      outputs: nil
    }

    output_step =
      data_step(
        name: output_name(state, reduce.name),
        hash: stable_hash({state.namespace, reduce.name, :reduce_output}),
        work: fn result ->
          if result.error,
            do: raise(result.error),
            else:
              Frame.value(
                result.input,
                result.accumulator,
                Enum.reverse(result.effects) |> Enum.concat()
              )
        end
      )

    {native_reduce, output_step}
  end

  defp put_reduce_output(state, reduce, workflow, native_reduce, output_step) do
    index = %{
      kind: :reduce,
      component: native_reduce,
      output: output_step.name,
      output_port: :out
    }

    %{
      state
      | workflow: workflow,
        outputs: Map.put(state.outputs, reduce.name, output_step),
        component_index: Map.put(state.component_index, reduce.name, index)
    }
  end

  defp add_subflow(subflow, state) do
    child_flow = Map.fetch!(state.subflows, subflow.flow)
    child_source_map = child_source_map(subflow.flow)
    child_namespace = state.namespace ++ [subflow.name]
    params_name = support_name(state, subflow.name, "subflow-input")

    params_step =
      runtime_step_named(params_name, state, :subflow_input, fn parent, runtime ->
        local = component_state(subflow, parent, runtime)
        params = ValueResolver.resolve(subflow.params, local) |> unwrap_ok!()
        {:jido_flow_input, params, local.input_frame}
      end)

    workflow = add_with_dependencies(state, subflow, params_step)
    input_validator = child_input_validator(subflow, child_namespace)

    child_state =
      compile_flow(
        child_flow,
        child_namespace,
        prefix_source_map(child_source_map, child_namespace),
        input_validator,
        state.subflows
      )

    child_output = child_output_step(subflow, child_state)

    child_workflow =
      Workflow.add(child_state.workflow, child_output, to: child_output_parents(child_state))

    boundary_name = support_name(state, subflow.name, "subflow")

    child_workflow = %{
      child_workflow
      | name: boundary_name,
        hash: stable_hash({child_namespace, :workflow}),
        input_ports: [in: [type: :any]],
        output_ports: [out: [type: :any, from: child_output.name]]
    }

    workflow = Workflow.add(workflow, child_workflow, to: params_step)

    output_step =
      data_step(
        name: output_name(state, subflow.name),
        hash: stable_hash({state.namespace, subflow.name, :subflow_output}),
        work: fn {:jido_subflow_output, output, parent_input} ->
          Frame.value(parent_input, output)
        end
      )

    workflow =
      Workflow.add(workflow, output_step, connections: [[from: {boundary_name, :out}, to: :in]])

    state = %{state | work_index: Map.merge(state.work_index, child_state.work_index)}

    state =
      index_work(state, subflow, [
        {params_step, :input},
        {input_validator, :input},
        {child_workflow, :input},
        {child_output, :output},
        {output_step, :output}
      ])

    child_digest = {child_namespace, child_state.semantic_digest}

    %{
      state
      | workflow: workflow,
        outputs: Map.put(state.outputs, subflow.name, output_step),
        component_index:
          Map.put(state.component_index, subflow.name, %{
            kind: :subflow,
            component: child_workflow,
            output: output_step.name,
            output_port: :out,
            children: child_state.component_index
          }),
        source_map: Map.merge(state.source_map, child_state.source_map),
        child_digests: [child_digest | state.child_digests ++ child_state.child_digests]
    }
  end

  defp child_input_validator(subflow, namespace) do
    data_step(
      name: scoped(namespace, "$input"),
      hash: stable_hash({namespace, :input_validator}),
      work: fn {:jido_flow_input, params, parent} ->
        case Validator.callback(subflow.flow, :validate_params, params) do
          {:ok, validated} when is_map(validated) ->
            {:jido_flow_input, validated, parent}

          {:ok, result} ->
            raise Error.invalid_execution_error("Subflow input validation must return a map", %{
                    value: result
                  })

          {:error, error} ->
            raise flow_boundary_error(error, subflow, :subflow_input, namespace)
        end
      end
    )
  end

  defp child_output_step(subflow, child_state) do
    namespace = child_state.namespace
    output = child_state.flow.output

    runtime_step_named(
      scoped(namespace, "$output"),
      child_state,
      :output_validator,
      fn parent, runtime ->
        local = output_state(output, parent, runtime)

        output =
          ValueResolver.resolve(output, %{
            input: local.input,
            context: local.context,
            results: local.results
          })
          |> unwrap_ok!()

        validated =
          with {:ok, output} <- Validator.output_shape(subflow.flow, output, :run),
               {:ok, output} <- Validator.callback(subflow.flow, :validate_output, output),
               {:ok, output} <-
                 Validator.output_shape(subflow.flow, output, :output_schema) do
            output
          else
            {:error, error} ->
              raise flow_boundary_error(error, subflow, :subflow_output, namespace)
          end

        {:jido_flow_input, _input, parent_input} = local.input_frame
        {:jido_subflow_output, validated, parent_input}
      end
    )
  end

  defp child_output_parents(child_state) do
    refs = child_state.flow.output |> Flow.Value.result_refs() |> Enum.uniq() |> Enum.sort()

    case refs do
      [] -> child_state.root_parent
      [ref] -> Map.fetch!(child_state.outputs, ref)
      refs -> Enum.map(refs, &Map.fetch!(child_state.outputs, &1))
    end
  end

  defp output_state(output, parent, runtime) do
    deps = output |> Flow.Value.result_refs() |> Enum.uniq() |> Enum.sort()
    dependency_state(deps, deps, parent, runtime)
  end

  defp child_source_map(module) do
    value =
      if function_exported?(module, :__jido_flow_source_map__, 0),
        do: module.__jido_flow_source_map__(),
        else: %{}

    case SourceMap.validate_source_map(value) do
      {:ok, source_map} ->
        source_map

      {:error, error} ->
        raise %{error | details: Map.put(error.details, :flow, module)}
    end
  end

  defp prefix_source_map(source_map, namespace) do
    prefix = Enum.flat_map(namespace, &[:components, &1])
    Map.new(source_map, fn {path, location} -> {prefix ++ path, location} end)
  end

  defp add_with_dependencies(state, component, native_component) do
    dependencies = Component.effective_dependencies(component)

    parents =
      case dependencies do
        [] -> state.root_parent
        names -> Enum.map(names, &Map.fetch!(state.outputs, &1))
      end

    case parents do
      nil ->
        Workflow.add(state.workflow, native_component, validate: :off)

      [] ->
        Workflow.add(state.workflow, native_component, validate: :off)

      [parent] ->
        Workflow.add(state.workflow, native_component, to: parent, validate: :off)

      parents when is_list(parents) ->
        Workflow.add(state.workflow, native_component, to: parents, validate: :off)

      parent ->
        Workflow.add(state.workflow, native_component, to: parent, validate: :off)
    end
  end

  defp index_work(state, component, nodes) do
    path = state.namespace ++ [component.name]
    kind = Component.kind(component)

    index =
      Enum.reduce(nodes, state.work_index, fn {node, role}, index ->
        metadata = %{component_path: path, kind: kind, role: role}

        metadata =
          case component do
            %FlowMap{action: action, on_error: policy} ->
              Map.merge(metadata, %{action: action, on_error: policy})

            %Jido.Flow.Step{action: action} ->
              Map.put(metadata, :action, action)

            _ ->
              metadata
          end

        Map.put(index, node.hash, metadata)
      end)

    %{state | work_index: index}
  end

  defp runtime_step(state, authored_name, kind, work) do
    runtime_step_named(output_name(state, authored_name), state, kind, work)
  end

  defp runtime_step_named(name, state, kind, work) do
    Step.new(
      name: name,
      hash: stable_hash({state.namespace, name, kind}),
      work: fn input, effective_context ->
        output = work.(Payload.unwrap(input), runtime_from_context(effective_context))

        if kind in [:map_input, :reduce_input],
          do: Enum.map(output, &Payload.new/1),
          else: Payload.new(output)
      end,
      meta_refs: [@runtime_ref]
    )
  end

  defp data_step(options) do
    work = Keyword.fetch!(options, :work)
    wrapped = fn input -> input |> Payload.unwrap() |> work.() |> Payload.new() end
    Step.new(Keyword.put(options, :work, wrapped))
  end

  defp component_state(component, parent, runtime) do
    dependencies = Component.effective_dependencies(component)
    references = Component.reference_dependencies(component)
    dependency_state(dependencies, references, parent, runtime)
  end

  defp dependency_state(dependencies, references, parent, runtime) do
    values = dependency_values(dependencies, parent)

    frame =
      case values do
        [] -> parent
        [{_name, output} | _rest] -> Frame.input_of(output)
      end

    referenced =
      if dependencies == references,
        do: values,
        else: Enum.filter(values, fn {name, _value} -> name in references end)

    results = Map.new(referenced, fn {name, result} -> {name, Frame.unwrap_value(result)} end)

    Frame.base_runtime_state(runtime, frame, results)
  end

  defp dependency_values([], _parent), do: []
  defp dependency_values([name], parent), do: [{name, parent}]
  defp dependency_values(names, parent) when is_list(parent), do: Enum.zip(names, parent)
  defp dependency_values(names, parent), do: Enum.zip(names, List.wrap(parent))

  defp resolve_and_run(state, expression, instruction) do
    with {:ok, params} <- ValueResolver.resolve(expression, state),
         {:ok, output, effects} <-
           Target.run(
             instruction,
             params,
             state.context,
             state.execution_id,
             state.target_runner
           ) do
      {:ok, state.input_frame, output, effects}
    else
      {:error, error} -> raise error
    end
  end

  defp run_dispatch(dispatch, state) do
    with {:ok, params} <- ValueResolver.resolve(dispatch.params, state),
         {:ok, decision, decision_effects} <-
           Target.run(
             Target.at(Target.dispatch(dispatch, :decision), []),
             params,
             state.context,
             state.execution_id,
             state.target_runner
           ) do
      case Target.run(
             Target.at(Target.dispatch(dispatch, :expander), []),
             decision,
             state.context,
             state.execution_id,
             state.target_runner
           ) do
        {:ok, output, effects} ->
          Frame.value(state.input_frame, output, decision_effects ++ effects)

        {:continue, %Transition{} = transition} ->
          {:jido_flow_transition, %{transition | effects: decision_effects}}

        {:error, error} ->
          raise error
      end
    else
      {:continue, %Transition{}} ->
        raise Error.execution_error(
                "action continuation is not allowed from this Flow position",
                %{component: dispatch.name, component_kind: :dispatch, retry: false}
              )

      {:error, error} ->
        raise error
    end
  end

  defp wrap_result({:ok, frame, output, effects}), do: Frame.value(frame, output, effects)

  defp unwrap_component_result({:ok, output, effects}), do: {output, effects}
  defp unwrap_component_result({:error, error}), do: raise(error)

  defp runtime_from_context(%{jido: runtime}), do: runtime

  defp unwrap_ok!({:ok, result}), do: result
  defp unwrap_ok!({:error, error}), do: raise(error)

  defp output_name(state, name), do: node_name(state.namespace, [segment(name)])

  defp support_name(state, name, suffix),
    do: node_name(state.namespace, ["$" <> segment(name), suffix])

  defp scoped(namespace, name), do: node_name(namespace, [to_string(name)])

  # Runic keeps one node per name. Escape authored segments so that a name
  # with "/" or "$" cannot equal a nested or support node name.
  defp node_name(namespace, tail),
    do: Enum.join(Enum.map(namespace, &segment/1) ++ tail, "/")

  defp segment(name), do: URI.encode(to_string(name), &(&1 not in ~c"%/$"))

  defp stable_hash(value), do: Components.fact_hash({:jido_flow, @compiler_version, value})

  defp digest(value) do
    Identity.hash_term(value)
    |> Base.encode16(case: :lower)
  end

  defp normalize_compile_error(error) when is_exception(error) do
    if Error.owned?(error) do
      error
    else
      Error.internal_error("flow compilation failed", %{
        phase: :flow_compilation,
        cause: error.__struct__,
        reason: Exception.message(error)
      })
    end
  end

  defp flow_boundary_error(error, subflow, phase, namespace) do
    Error.wrap(error, %{
      component: subflow.name,
      node_path: namespace,
      flow: subflow.flow,
      phase: phase
    })
  end
end
