defmodule Jido.Exec.Compiler do
  @moduledoc false

  alias Jido.Action.Error

  alias Jido.Exec.Node.{Action, Choice, Dispatch, Input, Loop, Output}
  alias Jido.Exec.Node.Map, as: MapComponent

  alias Jido.Flow
  alias Jido.Flow.{Definition, Graph, Identity}
  alias Jido.Instruction
  alias Runic.Workflow

  @spec compile(term(), keyword()) :: {:ok, Workflow.t()} | {:error, Exception.t()}
  def compile(target, opts \\ []) do
    with {:ok, opts} <- validate_options(opts),
         {:ok, instruction} <- normalize(target),
         :ok <- Instruction.validate_resolved(instruction) do
      compile_instruction(instruction, opts)
    end
  rescue
    error -> {:error, error}
  end

  @spec compile!(term(), keyword()) :: Workflow.t() | no_return()
  def compile!(target, opts \\ []) do
    case compile(target, opts) do
      {:ok, workflow} -> workflow
      {:error, error} when is_exception(error) -> raise error
      {:error, reason} -> raise Error.config_error("Exec compilation failed", %{reason: reason})
    end
  end

  @doc false
  def compile_nested!(%Instruction{kind: :flow} = instruction, opts) do
    with {:ok, flow} <- instruction_flow(instruction),
         {:ok, flow} <- validate(flow),
         {:ok, workflow} <-
           compile_flow(
             flow,
             opts
             |> with_module_source_map(instruction.target)
             |> Keyword.put(:validation_target, instruction.target)
           ) do
      workflow
    else
      {:error, error} when is_exception(error) ->
        raise error

      {:error, reason} ->
        raise Error.config_error("nested Flow compilation failed", %{reason: reason})
    end
  end

  @spec validate(Flow.t()) :: {:ok, Flow.t()} | {:error, Exception.t()}
  def validate(%Flow{} = flow) do
    with {:ok, flow} <- Flow.validate(flow),
         {:ok, _children} <- validate_component_targets(flow.components, [], %{}) do
      {:ok, flow}
    end
  end

  def validate(value), do: Flow.validate(value)

  defp compile_instruction(%Instruction{kind: :action} = instruction, opts) do
    name = Keyword.get(opts, :name)
    id = Keyword.get(opts, :id)
    node_opts = Enum.reject([name: name, id: id], fn {_key, value} -> is_nil(value) end)
    node = Action.new(instruction, node_opts)

    workflow =
      Workflow.new(
        name: "jido_action_#{node.name}",
        output_ports: [result: [type: :any, from: node.name]]
      )
      |> Workflow.add(node)

    {:ok, workflow}
  end

  defp compile_instruction(%Instruction{kind: :flow} = instruction, opts) do
    with {:ok, flow} <- instruction_flow(instruction),
         {:ok, flow} <- validate(flow) do
      compile_flow(
        flow,
        opts
        |> with_module_source_map(instruction.target)
        |> Keyword.put(:validation_target, instruction.target)
      )
    end
  end

  defp normalize(%Instruction{} = instruction), do: Instruction.resolve(instruction)
  defp normalize(%Flow{} = flow), do: Instruction.resolve(flow)

  defp normalize(module) when is_atom(module) and not is_nil(module),
    do: Instruction.resolve(module)

  defp normalize(target) do
    {:error,
     Error.config_error("unknown executable target", %{target: target, reason: :invalid_target})}
  end

  defp validate_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      allowed = [:source_map, :name, :id]

      case Keyword.keys(opts) -- allowed do
        [] -> {:ok, opts}
        unknown -> {:error, Error.config_error("unknown compile options", %{options: unknown})}
      end
    else
      {:error, Error.config_error("compile options must be a keyword list")}
    end
  end

  defp validate_options(_opts),
    do: {:error, Error.config_error("compile options must be a keyword list")}

  defp validate_component_targets(components, module_stack, children) do
    components
    |> Graph.canonical_components()
    |> Enum.reduce_while({:ok, children}, fn {name, component}, {:ok, children} ->
      case validate_component_target(name, component, module_stack, children) do
        {:ok, children} -> {:cont, {:ok, children}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp validate_component_target(
         name,
         %{kind: :call, call: {%Instruction{kind: :flow} = template, _params}},
         module_stack,
         children
       ) do
    with {:ok, instruction} <- bind_template(template, :flow, name),
         :ok <- reject_recursive_flow(instruction.target, module_stack),
         {:ok, children} <- validate_child_flow(instruction.target, module_stack, children) do
      {:ok, children}
    else
      {:error, error} -> {:error, target_error(error, name, :flow)}
    end
  end

  defp validate_component_target(name, component, _module_stack, children) do
    component
    |> Definition.calls()
    |> Enum.reduce_while({:ok, children}, fn {role, template, _params}, {:ok, children} ->
      field = validation_field(component, role)

      case bind_template(template, :action, name) do
        {:ok, _instruction} -> {:cont, {:ok, children}}
        {:error, error} -> {:halt, {:error, target_error(error, name, field)}}
      end
    end)
  end

  defp bind_template(template, expected, component) do
    case Instruction.bind(template, %{}, %{}) do
      {:ok, %Instruction{kind: ^expected} = instruction} ->
        {:ok, instruction}

      {:error, %{details: %{actual: actual}}}
      when actual in [:action, :flow] ->
        {:error,
         Jido.Flow.Error.validation_error("Flow component has the wrong target kind", %{
           component: component,
           expected: expected,
           actual: actual
         })}

      {:error, error} ->
        {:error, error}
    end
  end

  defp validate_child_flow(%Flow{} = child, module_stack, children) do
    validate_child_definition(child, child, module_stack, children)
  end

  defp validate_child_flow(module, module_stack, children) when is_atom(module) do
    case Map.fetch(children, module) do
      {:ok, _child} ->
        {:ok, children}

      :error ->
        with {:ok, child} <- instruction_flow(%Instruction{target: module, kind: :flow}),
             {:ok, children} <- validate_child_definition(child, module, module_stack, children) do
          {:ok, Map.put(children, module, child)}
        end
    end
  end

  defp validate_child_definition(child, identity, module_stack, children) do
    with {:ok, child} <- Flow.validate(child) do
      validate_component_targets(child.components, [identity | module_stack], children)
    end
  end

  defp reject_recursive_flow(identity, module_stack) do
    if identity in module_stack do
      {:error,
       Jido.Flow.Error.validation_error("recursive nested Flow cycle", %{
         flow: identity,
         module_stack: Enum.reverse([identity | module_stack])
       })}
    else
      :ok
    end
  end

  defp target_error(error, component, field) do
    details =
      error
      |> Map.get(:details, %{})
      |> Map.merge(%{component: component, field: field, cause: error.__struct__})

    tagged = Jido.Flow.Error.validation_error(Exception.message(error), details)

    case Map.get(error, :stacktrace) do
      nil -> tagged
      stacktrace -> %{tagged | stacktrace: stacktrace}
    end
  end

  defp validation_field(%{kind: kind}, _role) when kind in [:call, :map, :reduce, :iterate],
    do: :action

  defp validation_field(_component, role), do: role

  defp instruction_flow(%Instruction{target: %Flow{} = flow}), do: {:ok, flow}

  defp instruction_flow(%Instruction{target: module}) when is_atom(module) do
    try do
      case module.flow() do
        %Flow{} = flow ->
          {:ok, flow}

        value ->
          {:error, Error.config_error("Flow module returned invalid data", %{value: value})}
      end
    rescue
      error -> {:error, error}
    catch
      kind, reason ->
        {:error,
         Error.config_error("Flow module failed while returning its definition", %{
           module: module,
           kind: kind,
           reason: reason
         })}
    end
  end

  defp compile_flow(flow, opts) do
    digest = Identity.semantic_digest(flow)
    source_map = Keyword.get(opts, :source_map, %{})
    namespace = Keyword.get(opts, :namespace)
    boundary_name = Keyword.get(opts, :boundary_name)
    parent_component = Keyword.get(opts, :parent_component)
    input_params = Keyword.get(opts, :input_params)
    boundary_location = Keyword.get(opts, :boundary_location)
    validation_target = Keyword.get(opts, :validation_target)
    node_path_prefix = Keyword.get(opts, :node_path_prefix, [])
    ordered = Graph.canonical_components(flow.components)
    output = output_name(flow, digest, namespace)

    initial =
      Workflow.new(
        name: boundary_name || flow.name,
        input_ports: boundary_ports(boundary_name),
        output_ports: [result: [type: :any, from: output]]
      )

    {initial, root_parent} =
      add_flow_input(
        initial,
        namespace,
        boundary_name,
        parent_component,
        input_params,
        validation_target,
        boundary_location,
        node_path_prefix
      )

    with {:ok, workflow} <-
           add_flow_components(
             initial,
             ordered,
             digest,
             source_map,
             namespace,
             root_parent,
             node_path_prefix
           ) do
      output =
        Output.new(
          id: {:flow_output, digest, namespace},
          name: output,
          output: flow.output,
          effect_order: Enum.map(ordered, &elem(&1, 0)),
          parent_component: parent_component,
          validator: validation_target,
          location: Map.get(source_map, [:output])
        )

      terminals =
        flow.components
        |> terminal_components()
        |> Enum.map(&graph_name(namespace, &1))
        |> then(fn
          [] when not is_nil(root_parent) -> [root_parent]
          names -> names
        end)

      workflow = add_component(workflow, output, terminals)
      {:ok, workflow}
    end
  rescue
    error -> {:error, error}
  end

  defp add_flow_components(
         workflow,
         components,
         digest,
         source_map,
         namespace,
         root_parent,
         node_path_prefix
       ) do
    Enum.reduce_while(components, {:ok, workflow}, fn {name, node}, {:ok, current} ->
      graph_name = graph_name(namespace, name)

      case runtime_component(
             name,
             graph_name,
             node,
             digest,
             source_map,
             namespace,
             node_path_prefix
           ) do
        {:ok, component} ->
          dependencies =
            node
            |> Definition.effective_dependencies()
            |> Enum.map(&graph_name(namespace, &1))
            |> then(fn
              [] when not is_nil(root_parent) -> [root_parent]
              names -> names
            end)

          workflow = add_component(current, component, dependencies)

          {:cont, {:ok, workflow}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
  end

  defp runtime_component(
         name,
         graph_name,
         %{kind: :call, call: {%Instruction{kind: :action} = template, params}},
         digest,
         source_map,
         namespace,
         node_path_prefix
       ) do
    metadata = %{
      jido_flow: %{
        flow: digest,
        component: name,
        node_path: node_path_prefix ++ [name],
        params: params,
        location: Map.get(source_map, [:components, name])
      }
    }

    with {:ok, instruction} <- Instruction.bind(template, %{}, %{}, metadata) do
      {:ok,
       Action.new(instruction,
         id: {:flow, digest, namespace, name},
         name: graph_name
       )}
    end
  end

  defp runtime_component(
         name,
         graph_name,
         %{
           kind: :dispatch,
           decision: {%Instruction{kind: :action} = decision, params},
           expander: {%Instruction{kind: :action} = expander, _expander_params}
         },
         digest,
         source_map,
         namespace,
         _node_path_prefix
       ) do
    {:ok,
     Dispatch.new(
       id: {:flow, digest, namespace, name},
       name: graph_name,
       component: name,
       decision: decision,
       decision_params: params,
       expander: expander,
       location: Map.get(source_map, [:components, name])
     )}
  end

  defp runtime_component(
         name,
         graph_name,
         %{
           kind: :reduce,
           collection: collection,
           initial: initial,
           call: {%Instruction{kind: :action} = instruction, params}
         },
         digest,
         source_map,
         namespace,
         _node_path_prefix
       ) do
    {:ok,
     Loop.new(
       id: {:flow, digest, namespace, name},
       name: graph_name,
       kind: :reduce,
       component: name,
       collection: collection,
       initial: initial,
       instruction: instruction,
       params: params,
       location: Map.get(source_map, [:components, name])
     )}
  end

  defp runtime_component(
         name,
         graph_name,
         %{
           kind: :iterate,
           call: {%Instruction{kind: :action} = instruction, params},
           state: state,
           completion: completion,
           max_iterations: max_iterations
         },
         digest,
         source_map,
         namespace,
         _node_path_prefix
       ) do
    {:ok,
     Loop.new(
       id: {:flow, digest, namespace, name},
       name: graph_name,
       kind: :iterate,
       component: name,
       instruction: instruction,
       params: params,
       state: state,
       completion: completion,
       max_iterations: max_iterations,
       location: Map.get(source_map, [:components, name])
     )}
  end

  defp runtime_component(
         name,
         graph_name,
         %{
           kind: :map,
           collection: collection,
           call: {%Instruction{kind: :action} = instruction, params},
           on_error: on_error
         },
         digest,
         source_map,
         namespace,
         _node_path_prefix
       ) do
    {:ok,
     MapComponent.new(
       id: {:flow, digest, namespace, name},
       name: graph_name,
       component: name,
       collection: collection,
       instruction: instruction,
       params: params,
       on_error: on_error,
       location: Map.get(source_map, [:components, name])
     )}
  end

  defp runtime_component(
         name,
         graph_name,
         %{kind: :choice, options: options, fallback: fallback},
         digest,
         source_map,
         namespace,
         _node_path_prefix
       ) do
    {:ok,
     Choice.new(
       id: {:flow, digest, namespace, name},
       name: graph_name,
       component: name,
       options: options,
       fallback: fallback,
       location: Map.get(source_map, [:components, name])
     )}
  end

  defp runtime_component(
         name,
         _graph_name,
         %{kind: :call, call: {%Instruction{kind: :flow} = instruction, params}},
         digest,
         source_map,
         namespace,
         node_path_prefix
       ) do
    with {:ok, flow} <- instruction_flow(instruction),
         {:ok, flow} <- validate(flow) do
      child_namespace = nested_namespace(namespace, digest, name)
      child_source_map = module_source_map(instruction.target)

      compile_flow(flow,
        source_map: child_source_map,
        namespace: child_namespace,
        boundary_name: graph_name(namespace, name),
        parent_component: name,
        input_params: params,
        boundary_location: Map.get(source_map, [:components, name]),
        validation_target: instruction.target,
        node_path_prefix: node_path_prefix ++ [name]
      )
    end
  end

  defp runtime_component(
         name,
         _graph_name,
         node,
         _digest,
         _source_map,
         _namespace,
         _node_path_prefix
       ) do
    {:error,
     Error.config_error("Flow component is not supported by this compiler gate", %{
       component: name,
       kind: node.kind,
       reason: :unsupported_component
     })}
  end

  defp add_component(workflow, component, []), do: Workflow.add(workflow, component)

  defp add_component(workflow, component, [parent]) do
    source = Workflow.get_component(workflow, parent)

    if match?(%Workflow{}, source) or match?(%Workflow{}, component) do
      {source_port, _source_schema} = source |> Runic.Component.outputs() |> List.first()
      {target_port, _target_schema} = component |> Runic.Component.inputs() |> List.first()

      Workflow.add(workflow, component,
        connections: [[from: {parent, source_port}, to: target_port]]
      )
    else
      Workflow.add(workflow, component, to: parent)
    end
  end

  defp add_component(workflow, component, parents) do
    endpoints = Enum.map(parents, &component_endpoint(workflow, &1))
    Workflow.add(workflow, component, to: endpoints)
  end

  defp component_endpoint(workflow, parent) do
    case Workflow.get_component(workflow, parent) do
      %Workflow{output_ports: output_ports} ->
        {_port, port_options} = List.first(output_ports)
        Workflow.get_component(workflow, Keyword.fetch!(port_options, :from))

      component ->
        component
    end
  end

  defp terminal_components(components) do
    depended_on =
      components
      |> Enum.flat_map(fn {_name, node} -> Definition.effective_dependencies(node) end)
      |> MapSet.new()

    components
    |> Map.keys()
    |> Enum.reject(&MapSet.member?(depended_on, &1))
    |> Enum.sort()
  end

  defp add_flow_input(
         workflow,
         nil,
         nil,
         nil,
         nil,
         _validation_target,
         _location,
         _node_path_prefix
       ),
       do: {workflow, nil}

  defp add_flow_input(
         workflow,
         namespace,
         _boundary_name,
         parent_component,
         input_params,
         validation_target,
         location,
         node_path
       ) do
    input =
      Input.new(
        id: {:flow_input, namespace},
        name: graph_name(namespace, "__input__"),
        component: parent_component,
        params: input_params,
        validator: validation_target,
        location: location,
        node_path: node_path
      )

    {Workflow.add(workflow, input), input.name}
  end

  defp boundary_ports(nil), do: nil
  defp boundary_ports(_name), do: [in: [type: :any]]

  defp graph_name(nil, name), do: name
  defp graph_name(namespace, name), do: "#{namespace}/#{name}"

  defp nested_namespace(nil, digest, name),
    do: "__jido_nested__/#{binary_part(digest, 0, 12)}/#{name}"

  defp nested_namespace(namespace, digest, name),
    do: "#{namespace}/#{binary_part(digest, 0, 12)}/#{name}"

  defp output_name(flow, digest, namespace) do
    graph_name(namespace, "__jido_output__/#{flow.name}/#{binary_part(digest, 0, 12)}")
  end

  defp with_module_source_map(opts, target) do
    if Keyword.has_key?(opts, :source_map) do
      opts
    else
      Keyword.put(opts, :source_map, module_source_map(target))
    end
  end

  defp module_source_map(module) when is_atom(module) do
    if function_exported?(module, :__jido_flow_source_map__, 0) do
      module.__jido_flow_source_map__()
    else
      %{}
    end
  end

  defp module_source_map(_target), do: %{}
end
