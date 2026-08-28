defmodule Jido.Flow.Compiler do
  @moduledoc false

  alias Jido.Action.Output
  alias Jido.Exec.Action.Runner
  alias Jido.Exec.Continuation
  alias Jido.Flow
  alias Jido.Flow.Choice
  alias Jido.Flow.Compiled
  alias Jido.Flow.Error
  alias Jido.Flow.Dynamic
  alias Jido.Flow.Compiler.Choice, as: ChoiceRuntime
  alias Jido.Flow.Compiler.Expression
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

  @compiler_version 2
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
             | {:continue, Continuation.t()}
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
          {:ok, term()} | {:error, Exception.t()}
  def runtime_result(%Compiled{} = compiled, %Workflow{} = workflow, input, context)
      when is_map(input) and is_map(context) do
    result_names = compiled.output |> Flow.Expression.result_refs() |> Enum.uniq()

    result_names
    |> Enum.reduce_while({:ok, %{}}, fn name, {:ok, results} ->
      case Map.fetch(compiled.component_index, name) do
        {:ok, %{output: output_name}} ->
          case Workflow.results(workflow, [output_name], facts: true, all: true) do
            %{^output_name => facts} when is_list(facts) and facts != [] ->
              value = facts |> List.last() |> Map.fetch!(:value) |> unwrap_value()
              {:cont, {:ok, Map.put(results, name, value)}}

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
        |> resolve_and_run(component.params, component.action, Target.node(component))
        |> wrap_result()
      end)

    add_authored_output(state, component, step, step)
  end

  defp add_component(%Choice{} = component, state) do
    step =
      runtime_step(state, component.name, :choice, fn parent, runtime ->
        local = component_state(component, parent, runtime)

        case ChoiceRuntime.run(component, local) do
          {:continue, %Continuation{} = continuation, _metadata} ->
            continuation
            |> Continuation.with_frame(local.input_frame)
            |> Continuation.map_result(&value(local.input_frame, &1))

          result ->
            output = unwrap_component_result(result)
            value(local.input_frame, output)
        end
      end)

    add_authored_output(state, component, step, step)
  end

  defp add_component(%Iterate{} = component, state) do
    step =
      runtime_step(state, component.name, :iterate, fn parent, runtime ->
        local = component_state(component, parent, runtime)

        case IterateRuntime.run(component, local) do
          %Continuation{} = continuation ->
            continuation
            |> Continuation.with_frame(local.input_frame)
            |> Continuation.map_result(fn result ->
              result |> unwrap_component_result() |> then(&value(local.input_frame, &1))
            end)

          result ->
            result |> unwrap_component_result() |> then(&value(local.input_frame, &1))
        end
      end)

    add_authored_output(state, component, step, step)
  end

  defp add_component(%Dynamic{} = component, state) do
    step =
      runtime_step(state, component.name, :dynamic, fn parent, runtime ->
        local = component_state(component, parent, runtime)
        params = Expression.resolve(component.params, local) |> unwrap_ok!()
        run_dynamic_decision(component, params, 0, local, runtime)
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
          {:ok, collection} -> map_tokens(map, collection, local, runtime)
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
      Step.new(
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
              error: %{message: Exception.message(error)}
            })
            |> Map.delete(:item)

          {:fail_fast, {:error, error}} ->
            runtime.observer.({:error, span, error})
            raise error

          {on_error, {:continue, %Continuation{} = continuation}} ->
            continuation
            |> Continuation.with_frame(token.input)
            |> Continuation.map_result(fn output ->
              runtime.observer.({:stop, span})

              output =
                if on_error == :collect_errors,
                  do: %{status: :ok, value: output},
                  else: output

              token
              |> Map.put(:kind, :result)
              |> Map.put(:output, output)
              |> Map.delete(:item)
            end)
            |> Continuation.on_failure(fn error ->
              runtime.observer.({:error, span, error})

              if on_error == :collect_errors do
                {:ok,
                 token
                 |> Map.put(:kind, :result)
                 |> Map.put(:output, %{
                   status: :error,
                   error: %{message: Exception.message(error)}
                 })
                 |> Map.delete(:item)}
              else
                {:error, error}
              end
            end)
        end
    end)
  end

  defp map_tokens(map, collection, local, runtime) when is_list(collection) do
    if List.improper?(collection) do
      invalid_collection!(:map, map.name, collection)
    else
      case collection do
        [] ->
          [
            %{
              kind: :empty,
              input: local.input_frame,
              results: local.results,
              runtime: runtime
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
              results: local.results,
              runtime: runtime
            }
          end)
      end
    end
  end

  defp map_tokens(map, collection, _local, _runtime),
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
    step =
      runtime_step(state, reduce.name, :reduce, fn parent, runtime ->
        local = component_state(reduce, parent, runtime)

        with {:ok, collection} <- Expression.resolve(reduce.collection, local),
             {:ok, initial} <- Expression.resolve(reduce.initial, local) do
          run_reduce(reduce, collection, initial, local, runtime)
        else
          {:error, error} -> raise error
        end
      end)

    add_authored_output(state, reduce, step, step)
  end

  defp run_reduce(reduce, collection, initial, local, runtime) when is_list(collection) do
    if List.improper?(collection) do
      invalid_collection!(:reduce, reduce.name, collection)
    else
      validate_reduce_initial!(reduce, initial)

      collection
      |> Enum.with_index()
      |> reduce_items(reduce, initial, local, runtime)
    end
  end

  defp run_reduce(reduce, collection, _initial, _local, _runtime),
    do: invalid_collection!(:reduce, reduce.name, collection)

  defp reduce_items([], _reduce, accumulator, local, _runtime) do
    value(local.input_frame, accumulator)
  end

  defp reduce_items([{item, index} | rest], reduce, accumulator, local, runtime) do
    item_id = Identity.item_uuid(local.flow_digest, reduce.name, index)

    item_state =
      local
      |> Map.merge(%{
        item: item,
        item_index: index,
        item_id: item_id,
        accumulator: accumulator
      })

    owner = Target.reduce(reduce, %{item_index: index, item_id: item_id})

    span =
      runtime.observer.({
        :start,
        :reduce_item,
        %{node: reduce.name, target: reduce.action, item_index: index, item_id: item_id}
      })

    result =
      with {:ok, params} <- Expression.resolve(reduce.params, item_state) do
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
        reduce_items(rest, reduce, output, local, runtime)

      {:continue, %Continuation{} = continuation} ->
        continuation
        |> Continuation.with_frame(local.input_frame)
        |> Continuation.map_result(fn output ->
          runtime.observer.({:stop, span})
          reduce_items(rest, reduce, output, local, runtime)
        end)
        |> Continuation.on_failure(fn error ->
          runtime.observer.({:error, span, error})
          {:error, error}
        end)

      {:error, error} ->
        runtime.observer.({:error, span, error})
        raise error
    end
  end

  defp run_dynamic_decision(dynamic, input, cycle, local, runtime) do
    input = require_dynamic_input!(dynamic, input, :decision, cycle)
    owner = Target.dynamic(dynamic, :decision, cycle)

    case Target.run(
           dynamic.decision,
           input,
           runtime.context,
           owner,
           runtime.execution_id,
           runtime.target_runner
         ) do
      {:ok, decision} ->
        run_dynamic_expander(dynamic, decision, cycle, local, runtime)

      {:continue, %Continuation{} = continuation} ->
        continuation
        |> Continuation.with_frame(local.input_frame)
        |> Continuation.map_result(fn decision ->
          run_dynamic_expander(dynamic, decision, cycle, local, runtime)
        end)

      {:error, error} ->
        raise error
    end
  end

  defp run_dynamic_expander(dynamic, decision, cycle, local, runtime) do
    decision = require_dynamic_input!(dynamic, decision, :expander, cycle)
    owner = Target.dynamic(dynamic, :expander, cycle)

    case Target.run(
           dynamic.expander,
           decision,
           runtime.context,
           owner,
           runtime.execution_id,
           runtime.target_runner
         ) do
      {:ok, output} ->
        value(local.input_frame, output)

      {:continue, %Continuation{} = continuation} ->
        if cycle >= dynamic.max_continuations do
          raise Error.execution_error("dynamic continuation limit exceeded", %{
                  phase: :dynamic_limit,
                  node: dynamic.name,
                  max_continuations: dynamic.max_continuations,
                  cycle: cycle,
                  retry: false
                })
        end

        continuation
        |> Continuation.with_frame(local.input_frame)
        |> Continuation.map_result(fn output ->
          run_dynamic_decision(dynamic, output, cycle + 1, local, runtime)
        end)

      {:error, error} ->
        raise error
    end
  end

  defp require_dynamic_input!(dynamic, value, phase, cycle) do
    if is_map(value) and not is_struct(value) do
      value
    else
      raise Error.execution_error("dynamic Action input must be a plain map", %{
              phase: String.to_atom("dynamic_#{phase}_input"),
              node: dynamic.name,
              cycle: cycle,
              value_type: Expression.value_type(value),
              retry: false
            })
    end
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
      Step.new(
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
    Step.new(
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
            raise flow_boundary_error(error, subflow, :subflow_input)
        end
      end
    )
  end

  defp child_output_step(subflow, child_state) do
    Step.new(
      name: scoped(child_state.namespace, "$output"),
      hash: stable_hash({child_state.namespace, :output_validator}),
      work: fn parent ->
        local = component_state_from(child_state.flow.output, parent)
        output = Expression.resolve(child_state.flow.output, local) |> unwrap_ok!()

        validated =
          case subflow.flow.validate_output(output) do
            {:ok, value} -> value
            {:error, error} -> raise flow_boundary_error(error, subflow, :subflow_output)
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

  @doc false
  @spec continuation_flow(Flow.t(), [String.t()], (term() ->
                                                     {:ok, term()} | {:error, Exception.t()})) ::
          {:ok, Workflow.t(), Step.t()} | {:error, Exception.t()}
  def continuation_flow(%Flow{} = flow, namespace, finalizer)
      when is_list(namespace) and is_function(finalizer, 1) do
    with {:ok, attrs, subflows} <- Validation.prepare_executable(Map.from_struct(flow), []) do
      flow = struct!(Flow, attrs)
      state = compile_flow(flow, namespace, [], %{}, nil, subflows)

      output_step =
        Step.new(
          name: scoped(namespace, "$output"),
          hash: stable_hash({namespace, :continuation_output}),
          work: fn parent ->
            local = component_state_from(flow.output, parent)
            output = Expression.resolve(flow.output, local) |> unwrap_ok!()

            case finalizer.(output) do
              {:ok, validated} -> value(local.input_frame, validated)
              {:error, error} -> raise error
            end
          end
        )

      workflow = Workflow.add(state.workflow, output_step, to: child_output_parents(state))
      {:ok, workflow, output_step}
    end
  rescue
    error -> {:error, normalize_compile_error(error)}
  catch
    kind, reason ->
      {:error,
       Error.internal_error("continuation Flow compilation failed", %{
         phase: :continuation_compilation,
         kind: kind,
         reason: reason
       })}
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
        work.(input, runtime_from_context(effective_context))
      end,
      meta_refs: [@runtime_ref]
    )
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
         result <-
           Target.run(
             action,
             params,
             state.context,
             owner,
             state.execution_id,
             state.target_runner
           ) do
      case result do
        {:ok, output} ->
          {:ok, state.input_frame, output}

        {:continue, %Continuation{} = continuation} ->
          continuation
          |> Continuation.with_frame(state.input_frame)
          |> Continuation.map_result(&value(state.input_frame, &1))

        {:error, error} ->
          raise error
      end
    else
      {:error, error} -> raise error
    end
  end

  defp wrap_result({:ok, frame, output}), do: value(frame, output)
  defp wrap_result(%Continuation{} = continuation), do: continuation

  @doc false
  @spec continuation_action_step(String.t(), module(), Target.t()) :: Step.t()
  def continuation_action_step(name, action, owner)
      when is_binary(name) and is_atom(action) do
    Step.new(
      name: name,
      hash: stable_hash({:continuation, name, :action, action}),
      work: fn input, effective_context ->
        {:jido_continuation_input, _sequence, frame, params} = input
        runtime = runtime_from_context(effective_context)

        case Target.run(
               action,
               params,
               runtime.context,
               owner,
               runtime.execution_id,
               runtime.target_runner
             ) do
          {:ok, output} ->
            value(frame, output)

          {:continue, %Continuation{} = continuation} ->
            continuation
            |> Continuation.with_frame(frame)
            |> Continuation.map_result(&value(frame, &1))

          {:error, error} ->
            raise error
        end
      end,
      meta_refs: [@runtime_ref]
    )
  end

  @doc false
  @spec continuation_finalizer_step(String.t(), Continuation.t()) :: Step.t()
  def continuation_finalizer_step(name, %Continuation{} = continuation) when is_binary(name) do
    Step.new(
      name: name,
      hash: stable_hash({:continuation, name, :finalizer}),
      work: fn input, effective_context ->
        runtime = runtime_from_context(effective_context)
        output = unwrap_value(input)

        case output do
          {:jido_continuation_recovered, value} ->
            value

          output ->
            case Runner.validate_target_output(
                   continuation.origin_action,
                   output,
                   runtime.options
                 ) do
              {:ok, validated} ->
                stop_continuation_span(continuation)
                Continuation.resume(continuation, validated)

              {:error, _phase, error} ->
                error_continuation_span(continuation, error)
                raise error
            end
        end
      end,
      meta_refs: [@runtime_ref]
    )
  end

  defp stop_continuation_span(%Continuation{span: nil}), do: :ok
  defp stop_continuation_span(%Continuation{span: span}), do: Jido.Exec.Telemetry.stop(span)

  defp error_continuation_span(%Continuation{span: nil}, _error), do: :ok

  defp error_continuation_span(%Continuation{span: span}, error),
    do: Jido.Exec.Telemetry.error(span, error)

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

  defp flow_boundary_error(error, subflow, phase) do
    details =
      error
      |> Map.get(:details, %{})
      |> Map.merge(%{
        component: subflow.name,
        flow: subflow.flow,
        phase: phase,
        cause: error.__struct__
      })

    Error.invalid_execution_error(Exception.message(error), details)
  end
end
