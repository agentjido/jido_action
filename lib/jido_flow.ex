defmodule Jido.Flow do
  @moduledoc """
  Explicit composition of Jido actions.

  A flow is the Jido-owned intermediate representation for composing action
  leaves and supported flow primitives. `Jido.Exec` owns execution by projecting
  this IR into a `Runic.Workflow` at the runtime boundary.
  """

  alias Jido.Flow.Compiler
  alias Jido.Flow.Step
  alias Jido.Flow.Validator
  alias Jido.Instruction
  alias Runic.Workflow

  @name_schema Zoi.any(description: "Flow name")
               |> Zoi.refine({Validator, :validate_optional_component_name, []})

  @required_name_schema Zoi.any(description: "Flow entry name")
                        |> Zoi.refine({Validator, :validate_component_name, []})

  @dependency_schema Zoi.any(description: "Parent entry dependency")
                     |> Zoi.refine({Validator, :validate_dependency, []})
                     |> Zoi.default(nil)

  @entry_schema Zoi.map(
                  %{
                    type: Zoi.enum([:step, :map, :reduce, :accumulate, :workflow]),
                    name: @required_name_schema,
                    after: @dependency_schema
                  },
                  unrecognized_keys: :preserve
                )
                |> Zoi.refine({Validator, :validate_entry, []})

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
  @type callable :: function() | callable_ref()
  @type callable_ref :: {module(), atom()} | {:mfa, module(), atom()}
  @type entry_type :: :step | :map | :reduce | :accumulate | :workflow

  @type step_entry :: %{
          required(:type) => :step,
          required(:name) => atom() | String.t(),
          required(:action) => module(),
          required(:params) => map(),
          required(:context) => map(),
          required(:after) => dependency()
        }

  @type map_entry :: %{
          required(:type) => :map,
          required(:name) => atom() | String.t(),
          required(:mapper) => callable_ref(),
          required(:inputs) => keyword() | nil,
          required(:outputs) => keyword() | nil,
          required(:after) => dependency()
        }

  @type reduce_entry :: %{
          required(:type) => :reduce,
          required(:name) => atom() | String.t(),
          required(:init) => term(),
          required(:reducer) => callable_ref(),
          required(:map) => atom() | String.t() | nil,
          required(:inputs) => keyword() | nil,
          required(:outputs) => keyword() | nil,
          required(:after) => dependency()
        }

  @type accumulate_entry :: %{
          required(:type) => :accumulate,
          required(:name) => atom() | String.t(),
          required(:init) => term(),
          required(:reducer) => callable_ref(),
          required(:inputs) => keyword() | nil,
          required(:outputs) => keyword() | nil,
          required(:after) => dependency()
        }

  @type workflow_entry :: %{
          required(:type) => :workflow,
          required(:name) => atom() | String.t(),
          required(:workflow) => Workflow.t(),
          required(:after) => dependency()
        }

  @type entry ::
          step_entry() | map_entry() | reduce_entry() | accumulate_entry() | workflow_entry()
  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc """
  Creates an empty flow.
  """
  @spec new(name() | map() | keyword()) :: t()
  def new(name_or_opts \\ nil)

  def new(opts) when is_list(opts) do
    opts = keyword_opts!(opts, "Flow.new options")

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
  """
  @spec from_action(module() | Instruction.t(), map() | keyword(), keyword()) :: t()
  def from_action(action_or_instruction, params \\ %{}, opts \\ []) do
    opts = keyword_opts!(opts, "Flow.from_action options")
    {name, opts} = Keyword.pop(opts, :name)
    entry = step_entry(name, action_or_instruction, params, opts)

    entry.name
    |> new()
    |> add_entry(entry)
  end

  @doc """
  Wraps an existing Runic workflow as a runtime-only flow entry.
  """
  @spec from_workflow(Workflow.t()) :: t()
  def from_workflow(%Workflow{} = workflow) do
    entry_name = workflow.name || :workflow

    parse_flow!(%{
      name: workflow.name,
      flow: [
        %{
          type: :workflow,
          name: entry_name,
          workflow: workflow,
          after: nil
        }
      ]
    })
  end

  @doc """
  Returns the normalized Flow IR as a plain map.
  """
  @spec to_map(t()) :: %{name: name(), flow: [entry()], policies: list()}
  def to_map(%__MODULE__{} = flow) do
    flow = parse_flow!(flow)

    %{
      name: flow.name,
      flow: flow.flow,
      policies: flow.policies
    }
  end

  @doc """
  Projects a Jido flow into a Runic workflow.
  """
  @spec to_workflow(t()) :: Workflow.t()
  def to_workflow(%__MODULE__{} = flow), do: Compiler.to_workflow(flow)

  @doc """
  Adds a Jido action step to the flow.

  Options:

  - `:after` - parent step name or list of parent step names.
  - `:params` - static params merged before runtime fact params.
  - `:context` - static execution context.
  """
  @spec step(t(), atom() | String.t(), module() | Instruction.t(), keyword()) :: t()
  def step(%__MODULE__{} = flow, name, action_or_instruction, opts \\ []) do
    opts = keyword_opts!(opts, "Flow.step options")
    {after_dep, opts} = Keyword.pop(opts, :after)
    {params, opts} = Keyword.pop(opts, :params, %{})

    entry =
      name
      |> step_entry(action_or_instruction, params, opts)
      |> Map.put(:after, after_dep)

    add_entry(flow, entry)
  end

  @doc """
  Adds a map primitive to the flow.
  """
  @spec map(t(), atom() | String.t(), callable(), keyword()) :: t()
  def map(%__MODULE__{} = flow, name, mapper, opts \\ []) do
    {after_dep, opts} = primitive_opts!(opts, [:inputs, :outputs], :map)

    entry = %{
      type: :map,
      name: name,
      mapper: mapper,
      inputs: Keyword.get(opts, :inputs),
      outputs: Keyword.get(opts, :outputs),
      after: after_dep
    }

    add_entry(flow, entry)
  end

  @doc """
  Adds a reduce primitive to the flow.
  """
  @spec reduce(t(), atom() | String.t(), term(), callable(), keyword()) :: t()
  def reduce(%__MODULE__{} = flow, name, init, reducer, opts \\ []) do
    {after_dep, opts} = primitive_opts!(opts, [:map, :inputs, :outputs], :reduce)

    entry = %{
      type: :reduce,
      name: name,
      init: init,
      reducer: reducer,
      map: Keyword.get(opts, :map),
      inputs: Keyword.get(opts, :inputs),
      outputs: Keyword.get(opts, :outputs),
      after: after_dep
    }

    add_entry(flow, entry)
  end

  @doc """
  Adds an accumulator primitive to the flow.
  """
  @spec accumulate(t(), atom() | String.t(), term(), callable(), keyword()) :: t()
  def accumulate(%__MODULE__{} = flow, name, init, reducer, opts \\ []) do
    {after_dep, opts} = primitive_opts!(opts, [:inputs, :outputs], :accumulate)

    entry = %{
      type: :accumulate,
      name: name,
      init: init,
      reducer: reducer,
      inputs: Keyword.get(opts, :inputs),
      outputs: Keyword.get(opts, :outputs),
      after: after_dep
    }

    add_entry(flow, entry)
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
    |> projection_workflow()
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
    workflow = projection_workflow(flow_or_workflow)

    nodes =
      workflow
      |> node_map()
      |> Enum.map(fn {name, info} -> Map.put(info, :id, name) end)

    edges = graph_edges(workflow)

    %{nodes: include_edge_nodes(nodes, edges), edges: edges}
  end

  defp parse_flow!(%__MODULE__{} = flow), do: parse_flow!(Map.from_struct(flow))

  defp parse_flow!(attrs) when is_map(attrs) do
    attrs = normalize_attrs!(attrs)

    case Zoi.parse(@schema, attrs) do
      {:ok, flow} ->
        flow

      {:error, errors} ->
        raise ArgumentError, "invalid flow:\n" <> Zoi.prettify_errors(errors)
    end
  end

  defp normalize_attrs!(attrs) do
    %{
      name: get_field(attrs, :name, nil),
      flow: attrs |> get_field(:flow, []) |> normalize_entries(),
      policies: get_field(attrs, :policies, [])
    }
  end

  defp normalize_entries(entries) when is_list(entries),
    do: Enum.map(entries, &normalize_entry!/1)

  defp normalize_entries(entries), do: entries

  defp normalize_entry!(entry) when is_map(entry) do
    type = entry |> get_field(:type, nil) |> normalize_entry_type()
    name = get_field(entry, :name, nil)
    after_dep = get_field(entry, :after, nil)

    case type do
      :step ->
        %{
          type: :step,
          name: name,
          action: get_field(entry, :action, nil),
          params: Instruction.normalize_map!(get_field(entry, :params, %{}), :params),
          context: Instruction.normalize_map!(get_field(entry, :context, %{}), :context),
          after: after_dep
        }

      :map ->
        %{
          type: :map,
          name: name,
          mapper: get_field(entry, :mapper, nil) |> normalize_callable(1),
          inputs: get_field(entry, :inputs, nil),
          outputs: get_field(entry, :outputs, nil),
          after: after_dep
        }

      :reduce ->
        %{
          type: :reduce,
          name: name,
          init: get_field(entry, :init, nil),
          reducer: get_field(entry, :reducer, nil) |> normalize_callable(2),
          map: get_field(entry, :map, nil),
          inputs: get_field(entry, :inputs, nil),
          outputs: get_field(entry, :outputs, nil),
          after: after_dep
        }

      :accumulate ->
        %{
          type: :accumulate,
          name: name,
          init: get_field(entry, :init, nil),
          reducer: get_field(entry, :reducer, nil) |> normalize_callable(2),
          inputs: get_field(entry, :inputs, nil),
          outputs: get_field(entry, :outputs, nil),
          after: after_dep
        }

      :workflow ->
        %{
          type: :workflow,
          name: name,
          workflow: get_field(entry, :workflow, nil),
          after: after_dep
        }

      _ ->
        %{
          type: type,
          name: name,
          after: after_dep
        }
    end
  end

  defp normalize_entry!(_entry), do: raise(ArgumentError, "flow entries must be maps")

  defp normalize_entry_type(type) when type in [:step, :map, :reduce, :accumulate, :workflow],
    do: type

  defp normalize_entry_type(type) when is_binary(type) do
    case type do
      "step" -> :step
      "map" -> :map
      "reduce" -> :reduce
      "accumulate" -> :accumulate
      "workflow" -> :workflow
      _ -> type
    end
  end

  defp normalize_entry_type(type), do: type

  defp step_entry(name, action_or_instruction, params, opts) do
    {context, opts} = Keyword.pop(opts, :context, %{})

    if opts != [] do
      raise ArgumentError, "unknown flow step options: #{inspect(Keyword.keys(opts))}"
    end

    instruction = Instruction.normalize!(action_or_instruction, params, context)

    %{
      type: :step,
      name: name || Instruction.derive_action_name(instruction.action),
      action: instruction.action,
      params: instruction.params,
      context: instruction.context,
      after: nil
    }
  end

  defp add_entry(%__MODULE__{} = flow, entry) do
    ensure_available_name!(flow, entry.name)
    parse_flow!(%{flow | flow: flow.flow ++ [entry]})
  end

  defp primitive_opts!(opts, allowed_runic_opts, primitive) when is_list(opts) do
    opts = keyword_opts!(opts, "Flow.#{primitive} options")

    {after_dep, runic_opts} = Keyword.pop(opts, :after)
    primitive_name = "Flow.#{primitive}"

    if Keyword.has_key?(runic_opts, :name) do
      raise ArgumentError,
            "#{primitive_name} options must not include :name; pass the name as the second argument"
    end

    unknown = Keyword.keys(runic_opts) -- allowed_runic_opts

    if unknown != [] do
      raise ArgumentError,
            "unknown #{primitive_name} options: #{inspect(unknown)}"
    end

    {after_dep, runic_opts}
  end

  defp primitive_opts!(_opts, _allowed_runic_opts, primitive) do
    raise ArgumentError, "Flow.#{primitive} options must be a keyword list"
  end

  defp keyword_opts!(opts, context) when is_list(opts) do
    if Keyword.keyword?(opts) do
      opts
    else
      raise ArgumentError, "#{context} must be a keyword list, got: #{inspect(opts)}"
    end
  end

  defp keyword_opts!(opts, context) do
    raise ArgumentError, "#{context} must be a keyword list, got: #{inspect(opts)}"
  end

  defp ensure_available_name!(%__MODULE__{flow: entries}, name) do
    if Enum.any?(entries, &entry_named?(&1, name)) do
      raise ArgumentError, "flow already contains a component named #{inspect(name)}"
    end
  end

  defp entry_named?(%{name: name}, name), do: true

  defp entry_named?(%{type: :workflow, workflow: %Workflow{components: components}}, name) do
    Map.has_key?(components, name)
  end

  defp entry_named?(_entry, _name), do: false

  defp normalize_callable(nil, _arity), do: nil
  defp normalize_callable({module, function}, _arity), do: {module, function}
  defp normalize_callable({:mfa, module, function}, _arity), do: {:mfa, module, function}

  defp normalize_callable(fun, arity) when is_function(fun, arity) do
    case external_function(fun, arity) do
      {:ok, module, function} -> {module, function}
      :error -> fun
    end
  end

  defp normalize_callable(other, _arity), do: other

  defp external_function(fun, arity) do
    with {:type, :external} <- Function.info(fun, :type),
         {:module, module} <- Function.info(fun, :module),
         {:name, function} <- Function.info(fun, :name),
         {:arity, ^arity} <- Function.info(fun, :arity) do
      {:ok, module, function}
    else
      _ -> :error
    end
  end

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
      action: step.instruction.action,
      inputs: step.inputs,
      outputs: step.outputs
    }
  end

  defp node_info(%{__struct__: struct} = component) do
    %{
      type: struct,
      name: Map.get(component, :name),
      inputs: Runic.Component.inputs(component),
      outputs: Runic.Component.outputs(component)
    }
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

  defp projection_workflow(%__MODULE__{} = flow), do: to_workflow(flow)
  defp projection_workflow(%Workflow{} = workflow), do: workflow

  defp get_field(map, key, default) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
