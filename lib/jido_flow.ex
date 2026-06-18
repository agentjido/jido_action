defmodule Jido.Flow do
  @moduledoc """
  Explicit composition of Jido actions.

  A flow is a thin Jido-facing wrapper around a `Runic.Workflow`. It describes
  how action leaves and native Runic components are connected, while
  `Jido.Exec` owns execution.
  """

  alias Jido.Flow.Step
  alias Runic.Workflow

  defstruct [:name, :workflow]

  @type name :: atom() | String.t() | nil
  @type dependency :: atom() | String.t() | [atom() | String.t()]
  @type t :: %__MODULE__{name: name(), workflow: Workflow.t()}

  @doc """
  Creates an empty flow.
  """
  @spec new(name() | keyword()) :: t()
  def new(name_or_opts \\ nil)

  def new(opts) when is_list(opts) do
    opts
    |> Keyword.get(:name)
    |> new()
  end

  def new(nil) do
    from_workflow(Workflow.new())
  end

  def new(name) when is_atom(name) or is_binary(name) do
    from_workflow(Workflow.new(name))
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
    |> add_component(flow_name, step, nil)
  end

  @doc """
  Alias for `from_action/3`.
  """
  @spec single(module() | Jido.Instruction.t(), map() | keyword(), keyword()) :: t()
  def single(action_or_instruction, params \\ %{}, opts \\ []) when is_list(opts) do
    from_action(action_or_instruction, params, opts)
  end

  @doc """
  Wraps an existing Runic workflow as a flow.
  """
  @spec from_workflow(Workflow.t()) :: t()
  def from_workflow(%Workflow{} = workflow) do
    %__MODULE__{name: workflow.name, workflow: workflow}
  end

  @doc """
  Returns the underlying Runic workflow.
  """
  @spec to_workflow(t() | Workflow.t()) :: Workflow.t()
  def to_workflow(%__MODULE__{workflow: %Workflow{} = workflow}), do: workflow
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

    add_component(flow, name, node, after_dep)
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
  def policy(%__MODULE__{workflow: workflow} = flow, matcher, policy) do
    policies = Map.get(workflow, :scheduler_policies, [])
    scheduler_policy = {matcher, normalize_scheduler_policy!(policy)}

    %{flow | workflow: Workflow.set_scheduler_policies(workflow, policies ++ [scheduler_policy])}
  end

  @doc """
  Adds a native Runic component to the flow.

  This is the advanced escape hatch for stateful Runic components such as
  accumulators, FSMs, and state machines.
  """
  @spec component(t(), atom() | String.t(), struct(), keyword()) :: t()
  def component(%__MODULE__{} = flow, name, component, opts \\ []) when is_list(opts) do
    {after_dep, _opts} = Keyword.pop(opts, :after)
    validate_component_name!(component, name)
    component = maybe_name_component(component, name)
    add_component(flow, name, component, after_dep)
  end

  @doc """
  Validates that the value is a flow with a Runic workflow.
  """
  @spec validate(term()) :: {:ok, t()} | {:error, term()}
  def validate(%__MODULE__{workflow: %Workflow{}} = flow), do: {:ok, flow}
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

  defp add_component(%__MODULE__{workflow: workflow} = flow, name, component, after_dep) do
    ensure_available_name!(workflow, name)

    workflow =
      case after_dep do
        nil -> Workflow.add(workflow, component)
        dep -> Workflow.add(workflow, component, to: dep)
      end

    %{flow | name: workflow.name, workflow: workflow}
  end

  defp ensure_available_name!(%Workflow{components: components}, name) do
    if Map.has_key?(components, name) do
      raise ArgumentError, "flow already contains a component named #{inspect(name)}"
    end
  end

  defp validate_component_name!(%{name: nil}, _name), do: :ok
  defp validate_component_name!(%{name: name}, name), do: :ok

  defp validate_component_name!(%{name: component_name}, flow_name) do
    raise ArgumentError,
          "component name #{inspect(component_name)} does not match flow name #{inspect(flow_name)}"
  end

  defp validate_component_name!(_component, _name), do: :ok

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

  defp node_info(component) do
    %{
      type: component.__struct__,
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
