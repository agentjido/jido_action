defmodule Jido.Flow.Compiler do
  @moduledoc false

  alias Jido.Action.Output
  alias Jido.Exec.Transition
  alias Jido.Flow
  alias Jido.Flow.Choice
  alias Jido.Flow.Compiled
  alias Jido.Flow.Dispatch
  alias Jido.Flow.Error
  alias Jido.Flow.Compiler.Choice, as: ChoiceRuntime
  alias Jido.Flow.Compiler.Expression
  alias Jido.Flow.Compiler.Payload
  alias Jido.Flow.Compiler.Iterator, as: IterateRuntime
  alias Jido.Flow.Compiler.Target
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

  @compiler_version 5
  @runtime_ref %{
    kind: :context,
    target: :jido,
    context_key: :jido,
    field_path: []
  }

  @type target_phase :: :input | :execution | :output
  @type target_runner ::
          (module(), term(), map(), String.t(), Target.t() ->
             {:ok, term()}
             | {:continue, Transition.t()}
             | {:error, target_phase(), Exception.t()})

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
    with {:ok, source_map} <- source_map(opts, module_stack),
         {:ok, attrs, subflows} <-
           Validation.prepare_executable(Map.from_struct(flow), module_stack) do
      flow = struct!(Flow, attrs)

      with {:ok, compiled} <- compile_prepared(flow, source_map, subflows, module_stack) do
        {:ok, flow, compiled}
      end
    end
  end

  defp source_map(opts, module_stack) do
    case source_map(opts) do
      {:ok, source_map} ->
        {:ok, source_map}

      {:error, error} ->
        {:error, add_source_map_flow(error, module_stack)}
    end
  end

  defp add_source_map_flow(error, [module | _rest]),
    do: %{error | details: Map.put(error.details, :flow, module)}

  defp add_source_map_flow(error, []), do: error

  defp compile_prepared(flow, source_map, subflows, module_stack) do
    try do
      state = compile_flow(flow, [], module_stack, source_map, nil, subflows)

      digest_data = %{
        compiler: @compiler_version,
        flow: Identity.semantic_digest(flow),
        children: Enum.sort(state.child_digests)
      }

      {:ok,
       %Compiled{
         workflow: state.workflow,
         component_index: state.component_index,
         output: flow.output,
         source_map: state.source_map,
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

  @doc false
  @spec runtime_result(Compiled.t(), Workflow.t(), map(), map()) ::
          {:ok, term()} | {:continue, Transition.t()} | {:error, Exception.t()}
  def runtime_result(%Compiled{} = compiled, %Workflow{} = workflow, input, context)
      when is_map(input) and is_map(context) do
    result_names = compiled.output |> Flow.Expression.result_refs() |> Enum.uniq()

    result_names
    |> Enum.reduce_while({:ok, %{}}, fn name, {:ok, results} ->
      case Map.fetch(compiled.component_index, name) do
        {:ok, %{kind: kind, output: output_name}} ->
          case Workflow.results(workflow, [output_name], facts: true, all: true) do
            %{^output_name => facts} when is_list(facts) and facts != [] ->
              raw_value = facts |> List.last() |> Map.fetch!(:value) |> Payload.unwrap()

              case {kind, raw_value} do
                {:dispatch, {:jido_flow_transition, %Transition{} = transition}} ->
                  {:halt, {:continue, transition}}

                {_kind, value} ->
                  {:cont, {:ok, Map.put(results, name, unwrap_value(value))}}
              end

            _other ->
              {:halt,
               {:error,
                Error.execution_error("flow execution produced no final state", %{
                  component: name,
                  output: output_name
                })}}
          end

        :error ->
          {:halt,
           {:error,
            Error.execution_error("compiled Flow output is not indexed", %{component: name})}}
      end
    end)
    |> case do
      {:ok, results} ->
        Expression.resolve(compiled.output, %{input: input, context: context, results: results})

      {:continue, %Transition{} = transition} ->
        {:continue, transition}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc false
  @spec input_frame(term()) :: {:jido_flow_input, term(), nil}
  def input_frame(input), do: {:jido_flow_input, input, nil}

  defp source_map(opts) when is_map(opts) and not is_struct(opts),
    do: validate_source_map(opts)

  defp source_map(opts) when is_list(opts) do
    cond do
      not Keyword.keyword?(opts) ->
        source_map_error("Flow compile options must be a keyword list or source map")

      Keyword.keys(opts) -- [:source_map] != [] ->
        [option | _rest] = Keyword.keys(opts) -- [:source_map]
        source_map_error("unknown Flow compile option: #{inspect(option)}", %{option: option})

      Keyword.get_values(opts, :source_map) |> length() > 1 ->
        source_map_error("Flow compile option is duplicated", %{option: :source_map})

      true ->
        opts |> Keyword.get(:source_map, %{}) |> validate_source_map()
    end
  end

  defp source_map(_opts),
    do: source_map_error("Flow compile options must be a keyword list or source map")

  defp validate_source_map(source_map) when is_map(source_map) and not is_struct(source_map) do
    Enum.reduce_while(source_map, {:ok, %{}}, fn {path, location}, {:ok, validated} ->
      with :ok <- validate_source_path(path),
           :ok <- validate_source_location(location, path) do
        {:cont, {:ok, Map.put(validated, path, location)}}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp validate_source_map(_source_map), do: source_map_error("Flow source map must be a map")

  defp validate_source_path(path) when is_list(path) do
    cond do
      List.improper?(path) ->
        source_map_error("Flow source-map path must be a proper list")

      Enum.all?(path, &valid_source_path_segment?/1) ->
        :ok

      true ->
        source_map_error("Flow source-map path contains an invalid segment")
    end
  end

  defp validate_source_path(_path),
    do: source_map_error("Flow source-map path must be a proper list")

  defp valid_source_path_segment?(segment) when is_binary(segment), do: String.valid?(segment)
  defp valid_source_path_segment?(segment) when is_atom(segment), do: not is_nil(segment)
  defp valid_source_path_segment?(segment) when is_integer(segment), do: segment >= 0
  defp valid_source_path_segment?(_segment), do: false

  defp validate_source_location(location, path)
       when is_map(location) and not is_struct(location) do
    unknown_keys = Map.keys(location) -- [:file, :line, :column]

    cond do
      unknown_keys != [] ->
        source_map_error("Flow source location contains an unknown field", %{
          path: path,
          field: hd(unknown_keys)
        })

      not valid_source_file?(Map.get(location, :file)) ->
        source_map_error("Flow source location file must be a valid UTF-8 string", %{path: path})

      not valid_source_position?(Map.get(location, :line)) ->
        source_map_error("Flow source location line must be a positive integer", %{path: path})

      not valid_source_position?(Map.get(location, :column)) ->
        source_map_error("Flow source location column must be a positive integer", %{path: path})

      true ->
        :ok
    end
  end

  defp validate_source_location(_location, path),
    do: source_map_error("Flow source location must be a map", %{path: path})

  defp valid_source_file?(nil), do: true
  defp valid_source_file?(file) when is_binary(file), do: String.valid?(file)
  defp valid_source_file?(_file), do: false

  defp valid_source_position?(nil), do: true
  defp valid_source_position?(value), do: is_integer(value) and value > 0

  defp source_map_error(message, details \\ %{}),
    do: {:error, Error.validation_error(message, details)}

  defp compile_flow(flow, namespace, module_stack, source_map, root_parent, subflows) do
    workflow_name = scoped(namespace, flow.name)

    workflow =
      case root_parent do
        nil -> Workflow.new(name: workflow_name)
        %Step{} = parent -> Workflow.new(name: workflow_name) |> Workflow.add(parent)
      end

    initial = %{
      workflow: workflow,
      flow: flow,
      namespace: namespace,
      module_stack: module_stack,
      root_parent: root_parent,
      outputs: %{},
      component_index: %{},
      source_map: source_map,
      child_digests: [],
      subflows: subflows
    }

    flow.components
    |> Graph.canonical_components()
    |> Enum.reduce(initial, &add_component/2)
  end

  defp add_component(%FlowStep{} = component, state) do
    step =
      runtime_step(state, component.name, :step, fn parent, runtime ->
        local = component_state(component, parent, runtime)

        local
        |> resolve_and_run(
          component.params,
          component.action,
          Target.at(Target.node(component), state.namespace)
        )
        |> wrap_result()
      end)

    add_authored_output(state, component, step, step)
  end

  defp add_component(%Choice{} = component, state) do
    step =
      runtime_step(state, component.name, :choice, fn parent, runtime ->
        local = component_state(component, parent, runtime)
        result = ChoiceRuntime.run(component, Map.put(local, :namespace, state.namespace))
        output = unwrap_component_result(result)
        value(local.input_frame, output)
      end)

    add_authored_output(state, component, step, step)
  end

  defp add_component(%Iterate{} = component, state) do
    step =
      runtime_step(state, component.name, :iterate, fn parent, runtime ->
        local = component_state(component, parent, runtime)
        result = IterateRuntime.run(component, Map.put(local, :namespace, state.namespace))
        output = unwrap_component_result(result)
        value(local.input_frame, output)
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

    resolver =
      runtime_step_named(resolver_name, state, :map_input, fn parent, runtime ->
        local = component_state(map, parent, runtime)

        case Expression.resolve(map.collection, local) do
          {:ok, collection} -> map_tokens(map, collection, local)
          {:error, error} -> raise error
        end
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
        work: fn tokens -> collect_map_tokens(map, tokens) end
      )

    workflow = Workflow.add(workflow, output_step, to: collector.fan_in)

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

    runtime_step_named(name, state, :map_item, fn
      %{kind: :empty} = token, _runtime ->
        token

      %{kind: :item} = token, runtime ->
        local =
          base_runtime_state(runtime, token.input, token.results)
          |> Map.merge(%{
            item: token.item,
            item_index: token.index,
            item_id: token.id
          })

        owner =
          Target.map(map, %{
            item_index: token.index,
            item_id: token.id
          })
          |> Target.at(state.namespace)

        span =
          runtime.observer.({
            :start,
            :map_item,
            %{node: map.name, target: map.action, item_index: token.index, item_id: token.id}
          })

        outcome =
          with {:ok, params} <- Expression.resolve(map.params, local) do
            Target.run(
              map.action,
              params,
              runtime.context,
              owner,
              runtime.execution_id,
              runtime.target_runner
            )
          end

        case {map.on_error, outcome} do
          {_, {:ok, output}} ->
            runtime.observer.({:stop, span})

            output =
              if map.on_error == :collect_errors,
                do: %{status: :ok, value: output},
                else: output

            token |> Map.put(:kind, :result) |> Map.put(:output, output) |> Map.delete(:item)

          {:collect_errors, {:error, error}} ->
            runtime.observer.({:error, span, error})

            token
            |> Map.put(:kind, :result)
            |> Map.put(:output, %{
              status: :error,
              error: Error.to_map(error)
            })
            |> Map.delete(:item)

          {:fail_fast, {:error, error}} ->
            runtime.observer.({:error, span, error})
            raise error
        end
    end)
  end

  defp map_tokens(map, collection, local) when is_list(collection) do
    if List.improper?(collection) do
      invalid_collection!(:map, map.name, collection)
    else
      case collection do
        [] ->
          [
            %{
              kind: :empty,
              input: local.input_frame,
              results: local.results
            }
          ]

        items ->
          items
          |> Enum.with_index()
          |> Enum.map(fn {item, index} ->
            %{
              kind: :item,
              item: item,
              index: index,
              id: Identity.item_uuid(local.flow_digest, map.name, index),
              input: local.input_frame,
              results: local.results
            }
          end)
      end
    end
  end

  defp map_tokens(map, collection, _local),
    do: invalid_collection!(:map, map.name, collection)

  defp collect_map_tokens(map, tokens) do
    tokens = if is_list(tokens), do: tokens, else: [tokens]

    input =
      tokens
      |> Enum.find_value(fn token -> if is_map(token), do: Map.get(token, :input) end)

    values =
      tokens
      |> Enum.filter(&match?(%{kind: :result}, &1))
      |> Enum.sort_by(& &1.index)
      |> Enum.map(& &1.output)

    if is_nil(input) do
      raise Error.execution_error("Map collector did not receive Flow input", %{
              phase: :map_collection,
              node: map.name
            })
    end

    value(input, values)
  end

  defp add_reduce(reduce, state) do
    resolver_name = support_name(state, reduce.name, "reduce-input")

    resolver =
      runtime_step_named(resolver_name, state, :reduce_input, fn parent, runtime ->
        local = component_state(reduce, parent, runtime)

        with {:ok, collection} <- Expression.resolve(reduce.collection, local),
             {:ok, initial} <- Expression.resolve(reduce.initial, local) do
          reduce_tokens(reduce, collection, initial, local)
        else
          {:error, error} -> raise error
        end
      end)

    workflow = add_with_dependencies(state, reduce, resolver)
    {native_reduce, output_step} = reduce_components(state, reduce)
    workflow = Workflow.add(workflow, native_reduce, to: resolver)
    workflow = Workflow.add(workflow, output_step, to: native_reduce.fan_in)
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
          Payload.new(%{initialized: false, accumulator: nil, input: nil, error: nil})
        end,
        reducer: reduce_fun(reduce, state.namespace),
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
          if result.error, do: raise(result.error), else: value(result.input, result.accumulator)
        end
      )

    {native_reduce, output_step}
  end

  defp reduce_fun(reduce, namespace) do
    # Reduce uses Runic's simple FanIn mode. Its context is separate from facts.
    # Keep target failures in the aggregate for the output Step to report.
    fn payload, accumulator, effective_context ->
      token = Payload.unwrap(payload)
      aggregate = Payload.unwrap(accumulator)
      runtime = runtime_from_context(effective_context)

      result =
        try do
          reduce_token(reduce, token, aggregate, namespace, runtime)
        rescue
          error -> {:halt, %{aggregate | input: token.input, error: error}}
        catch
          kind, reason ->
            error =
              Error.execution_error("flow Reduce #{kind}", %{
                node: reduce.name,
                reason: reason
              })

            {:halt, %{aggregate | input: token.input, error: error}}
        end

      case result do
        {:halt, aggregate} -> {:halt, Payload.new(aggregate)}
        aggregate -> Payload.new(aggregate)
      end
    end
  end

  defp reduce_token(reduce, token, aggregate, namespace, runtime) do
    aggregate =
      if aggregate.initialized do
        aggregate
      else
        %{aggregate | initialized: true, accumulator: token.initial, input: token.input}
      end

    case token.kind do
      :init ->
        aggregate

      :item ->
        local =
          base_runtime_state(runtime, token.input, Map.get(token, :results, %{}))
          |> Map.merge(%{
            item: token.item,
            item_index: token.index,
            item_id: token.id,
            accumulator: aggregate.accumulator
          })

        owner =
          Target.reduce(reduce, %{
            item_index: token.index,
            item_id: token.id
          })
          |> Target.at(namespace)

        span =
          runtime.observer.({
            :start,
            :reduce_item,
            %{
              node: reduce.name,
              target: reduce.action,
              item_index: token.index,
              item_id: token.id
            }
          })

        result =
          with {:ok, params} <- Expression.resolve(reduce.params, local) do
            Target.run(
              reduce.action,
              params,
              runtime.context,
              owner,
              runtime.execution_id,
              runtime.target_runner
            )
          end

        case result do
          {:ok, output} ->
            runtime.observer.({:stop, span})
            %{aggregate | accumulator: output}

          {:error, error} ->
            runtime.observer.({:error, span, error})
            {:halt, %{aggregate | error: error}}
        end
    end
  end

  defp reduce_tokens(reduce, collection, initial, local) when is_list(collection) do
    if List.improper?(collection) do
      invalid_collection!(:reduce, reduce.name, collection)
    else
      validate_reduce_initial!(reduce, initial)

      init = %{
        kind: :init,
        initial: initial,
        input: local.input_frame,
        results: local.results
      }

      items =
        collection
        |> Enum.with_index()
        |> Enum.map(fn {item, index} ->
          %{
            kind: :item,
            item: item,
            index: index,
            id: Identity.item_uuid(local.flow_digest, reduce.name, index),
            input: local.input_frame,
            results: local.results,
            initial: initial
          }
        end)

      [init | items]
    end
  end

  defp reduce_tokens(reduce, collection, _initial, _local),
    do: invalid_collection!(:reduce, reduce.name, collection)

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
    if subflow.flow in state.module_stack do
      raise Error.validation_error("recursive Subflow reference", %{
              component: subflow.name,
              flow: subflow.flow,
              module_stack: Enum.reverse([subflow.flow | state.module_stack])
            })
    end

    child_flow = Map.fetch!(state.subflows, subflow.flow)
    child_source_map = child_source_map(subflow.flow)
    child_namespace = state.namespace ++ [subflow.name]
    params_name = support_name(state, subflow.name, "subflow-input")

    params_step =
      runtime_step_named(params_name, state, :subflow_input, fn parent, runtime ->
        local = component_state(subflow, parent, runtime)
        params = Expression.resolve(subflow.params, local) |> unwrap_ok!()
        {:jido_flow_input, params, local.input_frame}
      end)

    workflow = add_with_dependencies(state, subflow, params_step)
    input_validator = child_input_validator(subflow, child_namespace)

    child_state =
      compile_flow(
        child_flow,
        child_namespace,
        [subflow.flow | state.module_stack],
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
        work: fn {:jido_subflow_output, output, parent_input} -> value(parent_input, output) end
      )

    workflow =
      Workflow.add(workflow, output_step, connections: [[from: {boundary_name, :out}, to: :in]])

    child_digest = {subflow.name, Identity.semantic_digest(child_flow)}

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
        case subflow.flow.validate_params(params) do
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
    data_step(
      name: scoped(child_state.namespace, "$output"),
      hash: stable_hash({child_state.namespace, :output_validator}),
      work: fn parent ->
        local = component_state_from(child_state.flow.output, parent)
        output = Expression.resolve(child_state.flow.output, local) |> unwrap_ok!()

        validated =
          case subflow.flow.validate_output(output) do
            {:ok, value} ->
              value

            {:error, error} ->
              raise flow_boundary_error(error, subflow, :subflow_output, child_state.namespace)
          end

        {:jido_flow_input, _input, parent_input} = local.input_frame
        {:jido_subflow_output, validated, parent_input}
      end
    )
  end

  defp child_output_parents(child_state) do
    refs = child_state.flow.output |> Flow.Expression.result_refs() |> Enum.uniq() |> Enum.sort()

    case refs do
      [] -> child_state.root_parent
      [ref] -> Map.fetch!(child_state.outputs, ref)
      refs -> Enum.map(refs, &Map.fetch!(child_state.outputs, &1))
    end
  end

  defp component_state_from(output, parent) do
    deps = output |> Flow.Expression.result_refs() |> Enum.uniq() |> Enum.sort()

    runtime = %{
      input: nil,
      context: %{},
      options: [],
      execution_id: "",
      target_runner: nil,
      observer: nil,
      flow_digest: "",
      flow: ""
    }

    dependency_state(deps, deps, parent, runtime)
  end

  defp child_source_map(module) do
    value =
      if function_exported?(module, :__jido_flow_source_map__, 0),
        do: module.__jido_flow_source_map__(),
        else: %{}

    case validate_source_map(value) do
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
        [{_name, output} | _rest] -> input_of(output)
      end

    results =
      values
      |> Enum.filter(fn {name, _value} -> name in references end)
      |> Map.new(fn {name, result} -> {name, unwrap_value(result)} end)

    base_runtime_state(runtime, frame, results)
  end

  defp dependency_values([], _parent), do: []
  defp dependency_values([name], parent), do: [{name, parent}]
  defp dependency_values(names, parent) when is_list(parent), do: Enum.zip(names, parent)
  defp dependency_values(names, parent), do: Enum.zip(names, List.wrap(parent))

  defp base_runtime_state(runtime, frame, results) do
    %{
      execution_id: runtime.execution_id,
      flow: runtime.flow,
      flow_digest: runtime.flow_digest,
      input: public_input(frame),
      input_frame: frame,
      context: runtime.context,
      results: results,
      options: runtime.options,
      target_runner: runtime.target_runner,
      observer: runtime.observer,
      map_nodes: MapSet.new()
    }
  end

  defp resolve_and_run(state, expression, action, owner) do
    with {:ok, params} <- Expression.resolve(expression, state),
         {:ok, output} <-
           Target.run(
             action,
             params,
             state.context,
             owner,
             state.execution_id,
             state.target_runner
           ) do
      {:ok, state.input_frame, output}
    else
      {:error, error} -> raise error
    end
  end

  defp run_dispatch(dispatch, state) do
    with {:ok, params} <- Expression.resolve(dispatch.params, state),
         {:ok, decision} <-
           Target.run(
             dispatch.decision,
             params,
             state.context,
             Target.dispatch(dispatch, :decision),
             state.execution_id,
             state.target_runner
           ) do
      case Target.run(
             dispatch.expander,
             decision,
             state.context,
             Target.dispatch(dispatch, :expander),
             state.execution_id,
             state.target_runner
           ) do
        {:ok, output} -> value(state.input_frame, output)
        {:continue, %Transition{} = transition} -> {:jido_flow_transition, transition}
        {:error, error} -> raise error
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

  defp wrap_result({:ok, frame, output}), do: value(frame, output)

  defp unwrap_component_result({:ok, output}), do: output
  defp unwrap_component_result({:ok, output, _metadata}), do: output
  defp unwrap_component_result({:error, error, _state}), do: raise(error)
  defp unwrap_component_result({:error, error, _state, _metadata}), do: raise(error)

  defp value(frame, output), do: {:jido_flow_value, frame, output}
  defp unwrap_value({:jido_flow_value, _frame, output}), do: output
  defp unwrap_value(output), do: output

  defp input_of({:jido_flow_value, frame, _output}), do: frame
  defp input_of({:jido_flow_input, _input, _parent} = frame), do: frame
  defp input_of(value), do: value

  defp public_input({:jido_flow_input, input, _parent}), do: input
  defp public_input(input), do: input

  defp runtime_from_context(%{jido: runtime}), do: runtime

  defp unwrap_ok!({:ok, result}), do: result
  defp unwrap_ok!({:error, error}), do: raise(error)

  defp validate_reduce_initial!(reduce, initial) do
    valid? =
      case initial do
        %Output{} = output -> match?({:ok, _}, Output.validate(output))
        value -> is_map(value)
      end

    unless valid? do
      raise Error.execution_error("reduce initial value must be a map or Jido.Action.Output", %{
              phase: :reduce_initial,
              node: reduce.name,
              reason: :output_envelope_required,
              value_type: Expression.value_type(initial),
              retry: false
            })
    end
  end

  defp invalid_collection!(kind, name, collection) do
    raise Error.execution_error("#{kind} collection must resolve to a proper list", %{
            phase: String.to_atom("#{kind}_collection"),
            node: name,
            reason: :not_a_proper_list,
            value_type: Expression.value_type(collection),
            retry: false
          })
  end

  defp output_name(state, name), do: scoped(state.namespace, name)
  defp support_name(state, name, suffix), do: scoped(state.namespace, "$#{name}/#{suffix}")

  defp scoped([], name), do: to_string(name)
  defp scoped(namespace, name), do: Enum.join(namespace ++ [to_string(name)], "/")

  defp stable_hash(value), do: Components.fact_hash({:jido_flow, @compiler_version, value})

  defp digest(value) do
    :crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic]))
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
    details =
      error
      |> Map.get(:details, %{})
      |> Map.merge(%{
        component: subflow.name,
        node_path: namespace,
        flow: subflow.flow,
        phase: phase,
        cause: error.__struct__
      })

    Error.invalid_execution_error(Exception.message(error), details)
  end
end
