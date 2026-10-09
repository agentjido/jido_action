defmodule Jido.Exec.Node.Input do
  @moduledoc false

  alias Jido.Exec.{Frame, Portable, ValueResolver}
  alias Runic.Identity

  @enforce_keys [:id, :name, :hash, :component, :params]
  defstruct [:id, :name, :hash, :component, :params, :validator, :location, :node_path]

  @type t :: %__MODULE__{
          id: term(),
          name: atom() | String.t(),
          hash: Identity.t(),
          component: String.t(),
          params: term(),
          validator: module() | Jido.Flow.t() | nil
        }

  @doc false
  @spec new(keyword()) :: t()
  def new(opts) do
    opts =
      Keyword.validate!(opts, [
        :id,
        :name,
        :component,
        :params,
        :validator,
        :location,
        :node_path
      ])

    id = Keyword.fetch!(opts, :id)

    %__MODULE__{
      id: id,
      name: Keyword.fetch!(opts, :name),
      hash:
        Identity.digest(:component_definition, %{
          kind: "jido_flow_input",
          version: 1,
          id: inspect(id)
        }),
      component: Keyword.fetch!(opts, :component),
      params: Keyword.fetch!(opts, :params),
      validator: Keyword.get(opts, :validator),
      location: Keyword.get(opts, :location),
      node_path: Keyword.get(opts, :node_path, [Keyword.fetch!(opts, :component)])
    }
  end

  @doc false
  @spec resolve(t(), term(), map()) :: {:ok, Frame.nested_t()} | {:error, Exception.t()}
  def resolve(%__MODULE__{} = node, input, context) do
    with {:ok, parent} <- Frame.merge(input),
         {:ok, params} <-
           ValueResolver.resolve(node.params, Frame.resolver_state(parent, context)),
         {:ok, params} <-
           validate_params(node.validator, params, node.component, node.node_path),
         :ok <- Portable.validate(params, :output, context) do
      {:ok, Frame.nest(parent, params)}
    end
  end

  defp validate_params(nil, params, _component, _node_path), do: {:ok, params}

  defp validate_params(module, params, _component, node_path) when is_atom(module) do
    case module.validate_params(params) do
      {:error, %{details: details} = error} when is_map(details) ->
        {:error,
         %{error | details: Map.merge(details, %{node_path: node_path, phase: :subflow_input})}}

      result ->
        result
    end
  end

  defp validate_params(%Jido.Flow{} = flow, params, _component, node_path) do
    case Jido.Action.Validation.open_validate(flow.schema, params, %{
           module: Jido.Flow,
           flow: flow.name,
           context: "Flow"
         }) do
      {:error, %{details: details} = error} when is_map(details) ->
        {:error,
         %{error | details: Map.merge(details, %{node_path: node_path, phase: :subflow_input})}}

      result ->
        result
    end
  end
end

defimpl Runic.Identity.Projectable, for: Jido.Exec.Node.Input do
  def identity_document(node) do
    %{kind: :jido_flow_input, version: 1, id: inspect(node.id)}
  end
end

defimpl Runic.Workflow.Invokable, for: Jido.Exec.Node.Input do
  alias Jido.Exec.Node.Input
  alias Runic.Workflow
  alias Runic.Workflow.{CausalContext, Runnable}
  alias Runic.Workflow.Events.{ActivationConsumed, FactProduced}

  def match_or_execute(_node), do: :execute

  def invoke(node, workflow, fact) do
    {:ok, runnable} = prepare(node, workflow, fact)
    Workflow.apply_runnable(workflow, execute(node, runnable))
  end

  def prepare(node, workflow, fact) do
    context =
      CausalContext.new(
        node_hash: node.hash,
        input_fact: fact,
        ancestry_depth: Workflow.ancestry_depth(workflow, fact),
        run_context: Workflow.get_run_context(workflow, node.name)
      )

    {:ok, Runnable.new(node, fact, context)}
  end

  def execute(node, %Runnable{input_fact: fact, context: context} = runnable) do
    case Input.resolve(node, Jido.Exec.Fact.value(fact), context.run_context) do
      {:ok, value} ->
        result = Jido.Exec.Fact.from_runnable(runnable, value)

        Runnable.complete(runnable, result, [
          FactProduced.new(result, producer_label: :produced, weight: context.ancestry_depth + 1),
          %ActivationConsumed{fact_hash: fact.hash, node_hash: node.hash, from_label: :runnable}
        ])

      {:error, error} ->
        Runnable.fail(
          runnable,
          Jido.Exec.Source.attach(error, node.location, %{
            node: node.component,
            node_path: node.node_path
          })
        )
    end
  end
end

defimpl Runic.Component, for: Jido.Exec.Node.Input do
  def connectable?(_node, _other), do: true

  def connect(node, to, workflow) do
    workflow
    |> Runic.Workflow.add_step(to, node)
    |> Runic.Workflow.draw_connection(node, node, :component_of, properties: %{kind: :flow_input})
    |> Runic.Workflow.register_component(node)
  end

  def source(node) do
    quote do
      Jido.Exec.Node.Input.new(
        id: unquote(Macro.escape(node.id)),
        name: unquote(node.name),
        component: unquote(node.component),
        params: unquote(Macro.escape(node.params)),
        validator: unquote(Macro.escape(node.validator)),
        location: unquote(Macro.escape(node.location)),
        node_path: unquote(Macro.escape(node.node_path))
      )
    end
  end

  def hash(node), do: node.hash
  def inputs(_node), do: [in: [type: :any]]
  def outputs(_node), do: [out: [type: :any]]
end
