defmodule Jido.Flow do
  @moduledoc """
  Explicit composition of Jido actions.

  A flow is the Jido-owned intermediate representation for composing action
  leaves and supported flow primitives. `Jido.Exec` owns execution by projecting
  this IR into a `Runic.Workflow` at the runtime boundary.
  """

  alias Jido.Flow.Compiler
  alias Jido.Flow.Ref
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

  @entry_types [
    :step,
    :project,
    :map,
    :reduce,
    :accumulate,
    :workflow,
    :chain,
    :fanout,
    :collect,
    :debug,
    :trace,
    :switch
  ]

  @entry_schema Zoi.map(
                  %{
                    type: Zoi.enum(@entry_types),
                    name: @name_schema,
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
              inputs:
                Zoi.list(@required_name_schema, description: "Declared runtime input keys")
                |> Zoi.default([]),
              return:
                Zoi.any(description: "Flow return projection")
                |> Zoi.default(nil),
              policies:
                Zoi.list(Zoi.any(), description: "Runic scheduler policies")
                |> Zoi.default([])
            },
            coerce: true
          )

  @type name :: atom() | nil
  @type dependency :: atom() | [atom()] | nil
  @type value_ref ::
          Ref.value_ref()
  @type over_ref :: Ref.over_ref()
  @typedoc """
  Callable reference for Flow primitives.

  External captures such as `&MyModule.my_fun/1` are accepted and normalized to
  `{MyModule, :my_fun}`. Anonymous closures are rejected so flow entries remain
  data-oriented.
  """
  @type callable :: external_capture() | callable_ref()
  @type external_capture :: function()
  @type callable_ref :: {module(), atom()} | {:mfa, module(), atom()}
  @type entry_type ::
          :step
          | :project
          | :map
          | :reduce
          | :accumulate
          | :workflow
          | :chain
          | :fanout
          | :collect
          | :debug
          | :trace
          | :switch

  @type step_entry :: %{
          required(:type) => :step,
          required(:name) => atom(),
          required(:action) => module(),
          required(:params) => map(),
          required(:context) => map(),
          required(:after) => dependency()
        }

  @type map_entry :: %{
          required(:type) => :map,
          required(:name) => atom(),
          required(:mapper) => callable_ref(),
          optional(:source) => value_ref(),
          optional(:over) => over_ref() | nil,
          required(:inputs) => keyword() | nil,
          required(:outputs) => keyword() | nil,
          required(:after) => dependency()
        }

  @type project_entry :: %{
          required(:type) => :project,
          required(:name) => atom(),
          required(:from) => atom(),
          required(:path) => [atom() | non_neg_integer()],
          required(:mode) => :value,
          required(:after) => atom()
        }

  @type reduce_entry :: %{
          required(:type) => :reduce,
          required(:name) => atom(),
          required(:init) => term(),
          required(:reducer) => callable_ref(),
          optional(:source) => value_ref(),
          optional(:over) => over_ref() | nil,
          required(:map) => atom() | nil,
          required(:inputs) => keyword() | nil,
          required(:outputs) => keyword() | nil,
          required(:after) => dependency()
        }

  @type accumulate_entry :: %{
          required(:type) => :accumulate,
          required(:name) => atom(),
          required(:init) => term(),
          required(:reducer) => callable_ref(),
          optional(:source) => value_ref(),
          optional(:over) => over_ref() | nil,
          required(:inputs) => keyword() | nil,
          required(:outputs) => keyword() | nil,
          required(:after) => dependency()
        }

  @type workflow_entry :: %{
          required(:type) => :workflow,
          required(:name) => atom(),
          required(:workflow) => Workflow.t(),
          required(:after) => dependency()
        }

  @type chain_entry :: %{
          required(:type) => :chain,
          required(:name) => atom() | nil,
          required(:flow) => [entry()],
          required(:after) => dependency()
        }

  @type fanout_entry :: %{
          required(:type) => :fanout,
          required(:name) => atom() | nil,
          required(:from) => atom(),
          required(:flow) => [entry()],
          required(:after) => dependency()
        }

  @type collect_entry :: %{
          required(:type) => :collect,
          required(:name) => atom(),
          required(:arguments) => %{atom() => value_ref()},
          required(:after) => dependency()
        }

  @type debug_entry :: %{
          required(:type) => :debug,
          required(:name) => atom(),
          required(:source) => value_ref() | nil,
          required(:label) => String.t() | nil,
          required(:limit) => pos_integer() | nil,
          required(:after) => dependency()
        }

  @type trace_entry :: %{
          required(:type) => :trace,
          required(:name) => atom(),
          required(:source) => value_ref() | nil,
          required(:after) => dependency()
        }

  @type switch_entry :: %{
          required(:type) => :switch,
          required(:name) => atom(),
          required(:on) => value_ref(),
          required(:matches) => [map()],
          required(:default) => term(),
          required(:return?) => boolean(),
          required(:after) => dependency()
        }

  @type entry ::
          step_entry()
          | project_entry()
          | map_entry()
          | reduce_entry()
          | accumulate_entry()
          | workflow_entry()
          | chain_entry()
          | fanout_entry()
          | collect_entry()
          | debug_entry()
          | trace_entry()
          | switch_entry()
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

  def new(name) when is_atom(name) do
    parse_flow!(%{name: name})
  end

  def new(name) when is_binary(name) do
    raise ArgumentError, "flow name must be an atom, got: #{inspect(name)}"
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

  Runtime-only workflow entries created by `from_workflow/1` cannot be converted
  to map IR because they contain live `Runic.Workflow` structs.
  """
  @spec to_map(t()) :: %{
          name: name(),
          flow: [entry()],
          inputs: [atom()],
          return: value_ref() | atom() | nil,
          policies: list()
        }
  def to_map(%__MODULE__{} = flow) do
    flow = parse_flow!(flow)
    reject_runtime_workflow_entries!(flow)

    %{
      name: flow.name,
      flow: flow.flow,
      inputs: flow.inputs,
      return: flow.return,
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
  @spec step(t(), atom(), module() | Instruction.t(), keyword()) :: t()
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
  Adds a projection step to the flow.

  Projection is explicit data movement. It selects a path from a prior component
  output and emits the selected value as the next fact.

  Required options:

  - `:from` - source component name.
  - `:path` - non-empty list of atom map keys or non-negative list indexes.
  """
  @spec project(t(), atom(), keyword()) :: t()
  def project(%__MODULE__{} = flow, name, opts \\ []) do
    opts = keyword_opts!(opts, "Flow.project options")

    {from, opts} = Keyword.pop(opts, :from)
    {path, opts} = Keyword.pop(opts, :path)
    {mode, opts} = Keyword.pop(opts, :mode, :value)

    if opts != [] do
      raise ArgumentError, "unknown Flow.project options: #{inspect(Keyword.keys(opts))}"
    end

    add_entry(flow, %{
      type: :project,
      name: name,
      from: from,
      path: path,
      mode: mode,
      after: from
    })
  end

  @doc """
  Adds a map primitive to the flow.

  The mapper must be an external function capture or MFA tuple.
  """
  @spec map(t(), atom(), callable(), keyword()) :: t()
  def map(%__MODULE__{} = flow, name, mapper, opts \\ []) do
    {after_dep, opts} = primitive_opts!(opts, [:inputs, :outputs, :over], :map)
    {over_dep, opts} = Keyword.pop(opts, :over)

    entry = %{
      type: :map,
      name: name,
      mapper: mapper,
      source: nil,
      over: over_dep,
      inputs: Keyword.get(opts, :inputs),
      outputs: Keyword.get(opts, :outputs),
      after: after_dep || Ref.over_dependency(over_dep)
    }

    add_entry(flow, entry)
  end

  @doc """
  Adds a reduce primitive to the flow.

  The reducer must be an external function capture or MFA tuple.
  """
  @spec reduce(t(), atom(), term(), callable(), keyword()) :: t()
  def reduce(%__MODULE__{} = flow, name, init, reducer, opts \\ []) do
    {after_dep, opts} = primitive_opts!(opts, [:map, :inputs, :outputs, :over], :reduce)
    {over_dep, opts} = Keyword.pop(opts, :over)

    entry = %{
      type: :reduce,
      name: name,
      init: init,
      reducer: reducer,
      source: nil,
      over: over_dep,
      map: Keyword.get(opts, :map),
      inputs: Keyword.get(opts, :inputs),
      outputs: Keyword.get(opts, :outputs),
      after: after_dep || Ref.over_dependency(over_dep)
    }

    add_entry(flow, entry)
  end

  @doc """
  Adds an accumulator primitive to the flow.

  The reducer must be an external function capture or MFA tuple.
  """
  @spec accumulate(t(), atom(), term(), callable(), keyword()) :: t()
  def accumulate(%__MODULE__{} = flow, name, init, reducer, opts \\ []) do
    {after_dep, opts} = primitive_opts!(opts, [:inputs, :outputs, :over], :accumulate)
    {over_dep, opts} = Keyword.pop(opts, :over)

    entry = %{
      type: :accumulate,
      name: name,
      init: init,
      reducer: reducer,
      source: nil,
      over: over_dep,
      inputs: Keyword.get(opts, :inputs),
      outputs: Keyword.get(opts, :outputs),
      after: after_dep || Ref.over_dependency(over_dep)
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
  Validates that the value is a Jido flow.
  """
  @spec validate(term()) :: {:ok, t()} | {:error, term()}
  def validate(%__MODULE__{} = flow) do
    {:ok, parse_flow!(flow)}
  rescue
    error in [ArgumentError] -> {:error, error}
  end

  def validate(other), do: {:error, {:invalid_flow, other}}

  @doc """
  Returns Runic components keyed by component name.
  """
  @spec components(t()) :: map()
  def components(%__MODULE__{} = flow) do
    flow
    |> to_workflow()
    |> Workflow.components()
  end

  @doc """
  Returns Jido-oriented component metadata keyed by component name.
  """
  @spec node_map(t()) :: map()
  def node_map(%__MODULE__{} = flow) do
    flow
    |> components()
    |> Map.new(fn {name, component} ->
      {name, node_info(component)}
    end)
  end

  @doc """
  Returns a compact graph projection suitable for tests, diagnostics, and
  developer tooling.
  """
  @spec graph(t()) :: %{nodes: [map()], edges: [map()]}
  def graph(%__MODULE__{} = flow) do
    workflow = to_workflow(flow)

    nodes =
      workflow
      |> Workflow.components()
      |> Enum.map(fn {name, component} -> Map.put(node_info(component), :id, name) end)

    edges = graph_edges(workflow)

    %{nodes: include_edge_nodes(nodes, edges), edges: edges}
  end

  defp parse_flow!(%__MODULE__{} = flow), do: parse_flow!(Map.from_struct(flow))

  defp parse_flow!(attrs) when is_map(attrs) do
    reject_string_keys!(attrs, "flow")
    attrs = normalize_attrs!(attrs)

    case Zoi.parse(@schema, attrs) do
      {:ok, flow} ->
        flow

      {:error, errors} ->
        raise ArgumentError, "invalid flow:\n" <> Zoi.prettify_errors(errors)
    end
  end

  defp reject_runtime_workflow_entries!(%__MODULE__{flow: entries}) do
    if Enum.any?(entries, &match?(%{type: :workflow}, &1)) do
      raise ArgumentError,
            "runtime-only workflow entries cannot be converted with Jido.Flow.to_map/1"
    end
  end

  defp normalize_attrs!(attrs) do
    %{
      name: Map.get(attrs, :name),
      flow: attrs |> Map.get(:flow, []) |> normalize_entries(),
      inputs: Map.get(attrs, :inputs, []),
      return: Map.get(attrs, :return),
      policies: Map.get(attrs, :policies, [])
    }
  end

  defp normalize_entries(entries) when is_list(entries),
    do: Enum.map(entries, &normalize_entry!/1)

  defp normalize_entries(entries), do: entries

  defp normalize_entry!(entry) when is_map(entry) do
    reject_string_keys!(entry, "flow entry")

    type = entry |> Map.get(:type) |> normalize_entry_type()
    name = Map.get(entry, :name)
    after_dep = Map.get(entry, :after)

    case type do
      :step ->
        %{
          type: :step,
          name: name,
          action: Map.get(entry, :action),
          params: normalize_map!(Map.get(entry, :params, %{}), :params),
          context: normalize_map!(Map.get(entry, :context, %{}), :context),
          after: after_dep
        }

      :project ->
        from = Map.get(entry, :from)
        after_dep = if is_atom(from), do: from, else: nil

        %{
          type: :project,
          name: name,
          from: from,
          path: Map.get(entry, :path),
          mode: Map.get(entry, :mode, :value),
          after: after_dep
        }

      :map ->
        %{
          type: :map,
          name: name,
          mapper: entry |> Map.get(:mapper) |> normalize_callable(1),
          source: Map.get(entry, :source),
          over: Map.get(entry, :over),
          inputs: Map.get(entry, :inputs),
          outputs: Map.get(entry, :outputs),
          after: after_dep
        }

      :reduce ->
        %{
          type: :reduce,
          name: name,
          init: Map.get(entry, :init),
          reducer: entry |> Map.get(:reducer) |> normalize_callable(2),
          source: Map.get(entry, :source),
          over: Map.get(entry, :over),
          map: Map.get(entry, :map),
          inputs: Map.get(entry, :inputs),
          outputs: Map.get(entry, :outputs),
          after: after_dep
        }

      :accumulate ->
        %{
          type: :accumulate,
          name: name,
          init: Map.get(entry, :init),
          reducer: entry |> Map.get(:reducer) |> normalize_callable(2),
          source: Map.get(entry, :source),
          over: Map.get(entry, :over),
          inputs: Map.get(entry, :inputs),
          outputs: Map.get(entry, :outputs),
          after: after_dep
        }

      :workflow ->
        %{
          type: :workflow,
          name: name,
          workflow: Map.get(entry, :workflow),
          after: after_dep
        }

      :chain ->
        %{
          type: :chain,
          name: name,
          flow: entry |> Map.get(:flow, []) |> normalize_entries(),
          after: after_dep
        }

      :fanout ->
        from = Map.get(entry, :from)

        %{
          type: :fanout,
          name: name,
          from: from,
          flow: entry |> Map.get(:flow, []) |> normalize_entries(),
          after: after_dep || from
        }

      :collect ->
        %{
          type: :collect,
          name: name,
          arguments: normalize_map!(Map.get(entry, :arguments, %{}), :arguments),
          after: after_dep
        }

      :debug ->
        %{
          type: :debug,
          name: name,
          source: Map.get(entry, :source),
          label: Map.get(entry, :label),
          limit: Map.get(entry, :limit),
          after: after_dep
        }

      :trace ->
        %{
          type: :trace,
          name: name,
          source: Map.get(entry, :source),
          after: after_dep
        }

      :switch ->
        %{
          type: :switch,
          name: name,
          on: Map.get(entry, :on),
          matches: Map.get(entry, :matches, []),
          default: Map.get(entry, :default),
          return?: Map.get(entry, :return?, false),
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

  defp normalize_map!(nil, _field), do: %{}
  defp normalize_map!(value, _field) when is_map(value), do: value

  defp normalize_map!(value, _field) when is_list(value) do
    if Keyword.keyword?(value) do
      Map.new(value)
    else
      raise ArgumentError, "expected a map or keyword list, got: #{inspect(value)}"
    end
  end

  defp normalize_map!(value, field) do
    raise ArgumentError, "expected #{field} to be a map or keyword list, got: #{inspect(value)}"
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

  defp reject_string_keys!(map, context) do
    case Enum.find(Map.keys(map), &is_binary/1) do
      nil ->
        :ok

      key ->
        raise ArgumentError,
              "Flow IR uses atom keys for structural fields, got string key #{inspect(key)} in #{context}"
    end
  end
end
