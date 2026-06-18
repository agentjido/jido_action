defmodule Jido.Flow do
  @moduledoc """
  Explicit composition of Jido actions.

  A flow is the Jido-owned intermediate representation for composing action
  leaves and Runic components. `Jido.Exec` owns execution by projecting this IR
  into a `Runic.Workflow` at the runtime boundary.
  """

  alias Jido.Action.Util
  alias Jido.Flow.Step
  alias Runic.Workflow

  @name_schema Zoi.any(description: "Flow name")
               |> Zoi.refine({Util, :validate_optional_component_name, []})

  @required_name_schema Zoi.any(description: "Flow entry name")
                        |> Zoi.refine({Util, :validate_component_name, []})

  @dependency_schema Zoi.any(description: "Parent entry dependency")
                     |> Zoi.refine({__MODULE__, :validate_dependency, []})
                     |> Zoi.default(nil)

  @entry_schema Zoi.map(%{
                  type: Zoi.enum([:step, :component, :workflow]),
                  name: @required_name_schema,
                  component: Zoi.any(description: "Jido step or Runic component"),
                  after: @dependency_schema
                })
                |> Zoi.refine({__MODULE__, :validate_entry, []})

  @schema Zoi.struct(
            __MODULE__,
            %{
              name: @name_schema |> Zoi.default(nil),
              flow:
                Zoi.list(@entry_schema, description: "Ordered flow IR entries")
                |> Zoi.default([]),
              policies:
                Zoi.list(Zoi.any(), description: "Runic scheduler policies")
                |> Zoi.default([])
            },
            coerce: true
          )

  @type name :: atom() | String.t() | nil
  @type dependency :: atom() | String.t() | [atom() | String.t()] | nil
  @type entry_type :: :step | :component | :workflow
  @type entry :: %{
          required(:type) => entry_type(),
          required(:name) => atom() | String.t(),
          required(:component) => Step.t() | struct(),
          required(:after) => dependency()
        }
  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc false
  @spec validate_dependency(term(), keyword()) :: :ok | {:error, String.t()}
  def validate_dependency(value, _opts \\ [])
  def validate_dependency(nil, _opts), do: :ok

  def validate_dependency(values, opts) when is_list(values) do
    cond do
      values == [] ->
        {:error, "cannot be an empty list"}

      Enum.all?(values, &(Util.validate_component_name(&1, opts) == :ok)) ->
        :ok

      true ->
        {:error, "must contain only atom or string names"}
    end
  end

  def validate_dependency(value, opts), do: Util.validate_component_name(value, opts)

  @doc false
  @spec validate_entry(term(), keyword()) :: :ok | {:error, String.t()}
  def validate_entry(%{type: :step, component: %Step{}}, _opts), do: :ok
  def validate_entry(%{type: :component, component: %{__struct__: _}}, _opts), do: :ok
  def validate_entry(%{type: :workflow, component: %Workflow{}}, _opts), do: :ok

  def validate_entry(%{type: :step}, _opts),
    do: {:error, "step entries must contain a Jido.Flow.Step component"}

  def validate_entry(%{type: :component}, _opts),
    do: {:error, "component entries must contain a struct component"}

  def validate_entry(%{type: :workflow}, _opts),
    do: {:error, "workflow entries must contain a Runic.Workflow component"}

  def validate_entry(_entry, _opts), do: {:error, "must be a flow entry map"}

  @doc """
  Creates an empty flow.
  """
  @spec new(name() | map() | keyword()) :: t()
  def new(name_or_opts \\ nil)

  def new(opts) when is_list(opts) do
    opts
    |> Map.new()
    |> new()
  end

  def new(%{} = attrs) do
    parse_flow!(attrs)
  end

  def new(nil), do: parse_flow!(%{name: nil})

  def new(name) when is_atom(name) or is_binary(name) do
    parse_flow!(%{name: name})
  end

  @doc """
  Builds a one-step flow from an action module or `%Jido.Instruction{}`.

  This is explicit single-action runtime sugar: callers still execute the
  returned flow through `Jido.Exec`, so runtime policy remains Runic-owned.
  """
  @spec from_action(module() | Jido.Instruction.t(), map() | keyword(), keyword()) :: t()
  def from_action(action_or_instruction, params \\ %{}, opts \\ []) when is_list(opts) do
    {name, step_opts} = Keyword.pop(opts, :name)
    step = Step.new(action_or_instruction, params, Keyword.put(step_opts, :name, name))
    flow_name = name || step.name

    flow_name
    |> new()
    |> add_entry(:step, flow_name, step, nil)
  end

  @doc """
  Alias for `from_action/3`.
  """
  @spec single(module() | Jido.Instruction.t(), map() | keyword(), keyword()) :: t()
  def single(action_or_instruction, params \\ %{}, opts \\ []) when is_list(opts) do
    from_action(action_or_instruction, params, opts)
  end

  @doc """
  Wraps an existing Runic workflow as a runtime-only flow entry.
  """
  @spec from_workflow(Workflow.t()) :: t()
  def from_workflow(%Workflow{} = workflow) do
    parse_flow!(%{
      name: workflow.name,
      flow: [
        %{
          type: :workflow,
          name: workflow.name,
          component: workflow,
          after: nil
        }
      ]
    })
  end

  @doc """
  Projects a Jido flow into a Runic workflow.
  """
  @spec to_workflow(t() | Workflow.t()) :: Workflow.t()
  def to_workflow(%__MODULE__{} = flow) do
    {workflow, entries} = base_workflow(flow)

    entries
    |> Enum.reduce(workflow, &project_entry/2)
    |> apply_scheduler_policies(flow.policies)
  end

  def to_workflow(%Workflow{} = workflow), do: workflow

  @doc """
  Adds a Jido action step to the flow.

  Options:

  - `:after` - parent step name or list of parent step names.
  - `:params` - static params merged before runtime fact params.
  - `:context` - static execution context.
  """
  @spec step(t(), atom() | String.t(), module() | Jido.Instruction.t(), keyword()) :: t()
  def step(%__MODULE__{} = flow, name, action_or_instruction, opts \\ []) when is_list(opts) do
    {after_dep, opts} = Keyword.pop(opts, :after)
    {params, opts} = Keyword.pop(opts, :params, %{})

    node =
      action_or_instruction
      |> Step.new(params, Keyword.put(opts, :name, name))

    add_entry(flow, :step, name, node, after_dep)
  end

  @doc """
  Adds a Runic scheduler policy to the flow by matcher.

  Policies are runtime configuration, not step data. Matchers and policy maps
  follow `Runic.Workflow.SchedulerPolicy` conventions, for example:

      flow
      |> Jido.Flow.step(:load_cart, MyApp.LoadCart)
      |> Jido.Flow.policy(:load_cart, %{max_retries: 1, backoff: :none})
  """
  @spec policy(t(), term(), map() | keyword() | struct()) :: t()
  def policy(%__MODULE__{} = flow, matcher, policy) do
    parse_flow!(%{
      flow
      | policies: flow.policies ++ [{matcher, normalize_scheduler_policy!(policy)}]
    })
  end

  @doc """
  Adds a native Runic component to the flow.

  This is the advanced escape hatch for Runic primitives such as maps, reduces,
  accumulators, FSMs, state machines, and custom components.
  """
  @spec component(t(), atom() | String.t(), struct(), keyword()) :: t()
  def component(%__MODULE__{} = flow, name, component, opts \\ []) when is_list(opts) do
    {after_dep, _opts} = Keyword.pop(opts, :after)
    validate_component_name_match!(component, name)
    component = maybe_name_component(component, name)
    add_entry(flow, :component, name, component, after_dep)
  end

  @doc """
  Validates that the value is a Jido flow or wraps a Runic workflow as one.
  """
  @spec validate(term()) :: {:ok, t()} | {:error, term()}
  def validate(%__MODULE__{} = flow), do: {:ok, parse_flow!(flow)}
  def validate(%Workflow{} = workflow), do: {:ok, from_workflow(workflow)}
  def validate(other), do: {:error, {:invalid_flow, other}}

  @doc """
  Returns Runic components keyed by component name.
  """
  @spec components(t() | Workflow.t()) :: map()
  def components(flow_or_workflow) do
    flow_or_workflow
    |> to_workflow()
    |> Workflow.components()
  end

  @doc """
  Returns Jido-oriented component metadata keyed by component name.
  """
  @spec node_map(t() | Workflow.t()) :: map()
  def node_map(flow_or_workflow) do
    flow_or_workflow
    |> components()
    |> Map.new(fn {name, component} ->
      {name, node_info(component)}
    end)
  end

  @doc """
  Returns a compact graph projection suitable for tests, diagnostics, and
  developer tooling.
  """
  @spec graph(t() | Workflow.t()) :: %{nodes: [map()], edges: [map()]}
  def graph(flow_or_workflow) do
    workflow = to_workflow(flow_or_workflow)

    nodes =
      workflow
      |> node_map()
      |> Enum.map(fn {name, info} -> Map.put(info, :id, name) end)

    edges = graph_edges(workflow)

    %{nodes: include_edge_nodes(nodes, edges), edges: edges}
  end

  defp parse_flow!(%__MODULE__{} = flow), do: parse_flow!(Map.from_struct(flow))

  defp parse_flow!(attrs) when is_map(attrs) do
    case Zoi.parse(@schema, attrs) do
      {:ok, flow} ->
        flow

      {:error, errors} ->
        raise ArgumentError, "invalid flow:\n" <> Zoi.prettify_errors(errors)
    end
  end

  defp add_entry(%__MODULE__{} = flow, type, name, component, after_dep) do
    ensure_available_name!(flow, name)

    entry = %{
      type: type,
      name: name,
      component: component,
      after: after_dep
    }

    parse_flow!(%{flow | flow: flow.flow ++ [entry]})
  end

  defp base_workflow(%__MODULE__{name: name, flow: flow_entries}) do
    case flow_entries do
      [%{type: :workflow, component: %Workflow{} = workflow, after: nil} | entries] ->
        {workflow, entries}

      entries ->
        {new_workflow(name), entries}
    end
  end

  defp new_workflow(nil), do: Workflow.new()
  defp new_workflow(name), do: Workflow.new(name)

  defp project_entry(
         %{type: :workflow, component: %Workflow{} = child, after: after_dep},
         workflow
       ) do
    add_component_to_workflow(workflow, child, after_dep)
  end

  defp project_entry(%{component: component, after: after_dep}, workflow) do
    add_component_to_workflow(workflow, component, after_dep)
  end

  defp add_component_to_workflow(%Workflow{} = workflow, component, nil) do
    Workflow.add(workflow, component)
  end

  defp add_component_to_workflow(%Workflow{} = workflow, component, after_dep) do
    Workflow.add(workflow, component, to: after_dep)
  end

  defp apply_scheduler_policies(%Workflow{} = workflow, []), do: workflow

  defp apply_scheduler_policies(%Workflow{} = workflow, policies) do
    existing_policies = Map.get(workflow, :scheduler_policies, [])
    Workflow.set_scheduler_policies(workflow, existing_policies ++ policies)
  end

  defp ensure_available_name!(%__MODULE__{flow: entries}, name) do
    if Enum.any?(entries, &entry_named?(&1, name)) do
      raise ArgumentError, "flow already contains a component named #{inspect(name)}"
    end
  end

  defp entry_named?(%{name: name}, name), do: true

  defp entry_named?(%{type: :workflow, component: %Workflow{components: components}}, name) do
    Map.has_key?(components, name)
  end

  defp entry_named?(_entry, _name), do: false

  defp validate_component_name_match!(%{name: nil}, _name), do: :ok
  defp validate_component_name_match!(%{name: name}, name), do: :ok

  defp validate_component_name_match!(%{name: component_name}, flow_name) do
    raise ArgumentError,
          "component name #{inspect(component_name)} does not match flow name #{inspect(flow_name)}"
  end

  defp validate_component_name_match!(_component, _name), do: :ok

  defp maybe_name_component(%{name: nil} = component, name), do: %{component | name: name}
  defp maybe_name_component(component, _name), do: component

  defp normalize_scheduler_policy!(%Runic.Workflow.SchedulerPolicy{} = policy),
    do: Map.from_struct(policy)

  defp normalize_scheduler_policy!(policy) when is_map(policy), do: policy

  defp normalize_scheduler_policy!(policy) when is_list(policy) do
    if Keyword.keyword?(policy) do
      Map.new(policy)
    else
      raise ArgumentError,
            "expected scheduler policy to be a keyword list, got: #{inspect(policy)}"
    end
  end

  defp normalize_scheduler_policy!(policy) do
    raise ArgumentError,
          "expected scheduler policy to be a map, keyword list, or Runic.Workflow.SchedulerPolicy, got: #{inspect(policy)}"
  end

  defp node_info(%Step{} = step) do
    %{
      type: :jido_action,
      name: step.name,
      action: step.action,
      inputs: step.inputs,
      outputs: step.outputs
    }
  end

  defp node_info(%{__struct__: struct} = component) do
    %{
      type: struct,
      name: Map.get(component, :name),
      inputs: safe_ports(component, :inputs),
      outputs: safe_ports(component, :outputs)
    }
  end

  defp safe_ports(component, function) do
    apply(Runic.Component, function, [component])
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp graph_edges(%Workflow{graph: graph}) do
    graph
    |> Multigraph.edges(by: :flow)
    |> Enum.map(fn %Multigraph.Edge{v1: from, v2: to, label: label} ->
      %{
        from: component_id(from),
        to: component_id(to),
        label: label
      }
    end)
    |> Enum.uniq()
  end

  defp include_edge_nodes(nodes, edges) do
    known_ids = MapSet.new(Enum.map(nodes, & &1.id))

    edge_nodes =
      edges
      |> Enum.flat_map(&[&1.from, &1.to])
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(known_ids, &1))
      |> Enum.map(fn id ->
        %{
          id: id,
          type: :runic_internal,
          name: id,
          inputs: [],
          outputs: []
        }
      end)

    nodes ++ edge_nodes
  end

  defp component_id(%Runic.Workflow.Root{}), do: :root
  defp component_id(%{name: name}) when not is_nil(name), do: name
  defp component_id(%{hash: hash}) when not is_nil(hash), do: hash
  defp component_id(component), do: inspect(component)
end
