defmodule Jido.Exec.Node.Map do
  @moduledoc false

  alias Jido.Exec.Frame
  alias Jido.Exec.Node.Action
  alias Jido.Exec.Node.Map.Collection
  alias Jido.Instruction
  alias Runic.Identity
  alias Runic.Workflow

  @enforce_keys [:id, :name, :hash, :component, :collection, :instruction, :params, :on_error]
  defstruct [
    :id,
    :name,
    :hash,
    :component,
    :collection,
    :instruction,
    :params,
    :on_error,
    :location
  ]

  def new(opts) do
    opts =
      Keyword.validate!(opts, [
        :id,
        :name,
        :component,
        :collection,
        :instruction,
        :params,
        :on_error,
        :location
      ])

    id = Keyword.fetch!(opts, :id)

    %__MODULE__{
      id: id,
      name: Keyword.fetch!(opts, :name),
      hash: Identity.digest(:component_definition, %{kind: "jido_map", version: 1, id: id}),
      component: Keyword.fetch!(opts, :component),
      collection: Keyword.fetch!(opts, :collection),
      instruction: Keyword.fetch!(opts, :instruction),
      params: Keyword.fetch!(opts, :params),
      on_error: Keyword.fetch!(opts, :on_error),
      location: Keyword.get(opts, :location)
    }
  end

  @doc false
  def connect(%__MODULE__{} = node, parents, %Workflow{} = workflow) do
    collection =
      Collection.new(
        id: {node.id, :collection},
        name: internal_name(node, "collection"),
        component: node.component,
        value: node.collection,
        location: node.location
      )

    fan_out = %Runic.Workflow.FanOut{
      hash:
        Identity.digest(:component_definition, %{
          kind: "jido_map_fan_out",
          version: 1,
          id: node.id
        }),
      name: internal_name(node, "fan_out")
    }

    metadata = %{
      jido_flow: %{
        component: node.component,
        mode: {:map, node.on_error},
        params: node.params,
        location: node.location
      }
    }

    {:ok, instruction} = Instruction.bind(node.instruction, %{}, %{}, metadata)

    action =
      Action.new(instruction,
        id: {node.id, :action},
        name: internal_name(node, "action")
      )

    fan_in = %Runic.Workflow.FanIn{
      hash:
        Identity.digest(:component_definition, %{
          kind: "jido_map_fan_in",
          version: 1,
          id: node.id
        }),
      name: internal_name(node, "fan_in"),
      map: node.name,
      init: &__MODULE__.initial/0,
      reducer: &__MODULE__.collect/2,
      mergeable: false,
      meta_refs: []
    }

    workflow
    |> connect_from(parents, collection)
    |> Workflow.add_step(collection, fan_out)
    |> Workflow.add_step(fan_out, action)
    |> Workflow.add_step(action, fan_in)
    |> Workflow.draw_connection(fan_out, fan_in, :fan_in)
    |> Workflow.add_step(fan_in, node)
    |> Workflow.draw_connection(node, node, :component_of, properties: %{kind: :map})
    |> Workflow.register_component(node)
  end

  @doc false
  def initial, do: nil

  @doc false
  def collect({:jido_map_result, frame, component, index, on_error, result}, accumulator) do
    frame = accumulator || frame
    Frame.put_collection_item(frame, component, index, {on_error, result})
  end

  @doc false
  def pass({:jido_flow_frame, 1, _input, _results, _effects} = frame), do: frame

  def pass({:jido_nested_flow_frame, 1, _parent, _child} = frame), do: frame

  defp connect_from(workflow, [], child), do: Workflow.add_step(workflow, child)
  defp connect_from(workflow, [parent], child), do: Workflow.add_step(workflow, parent, child)
  defp connect_from(workflow, parents, child), do: Workflow.add_step(workflow, parents, child)

  defp internal_name(node, kind), do: "__jido_map__/#{node.name}/#{kind}"
end

defimpl Runic.Identity.Projectable, for: Jido.Exec.Node.Map do
  def identity_document(node) do
    %{kind: :jido_map, version: 1, id: inspect(node.id)}
  end
end

defimpl Runic.Workflow.Invokable, for: Jido.Exec.Node.Map do
  alias Jido.Exec.Node.Map
  alias Runic.Workflow
  alias Runic.Workflow.{CausalContext, Fact, Runnable}
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
        ancestry_depth: Workflow.ancestry_depth(workflow, fact)
      )

    {:ok, Runnable.new(node, fact, context)}
  end

  def execute(node, %Runnable{input_fact: fact, context: context} = runnable) do
    value = Map.pass(fact.value)
    result = Fact.new(value: value, ancestry: {node.hash, fact.hash})

    Runnable.complete(runnable, result, [
      FactProduced.new(result, producer_label: :produced, weight: context.ancestry_depth + 1),
      %ActivationConsumed{fact_hash: fact.hash, node_hash: node.hash, from_label: :runnable}
    ])
  end
end

defimpl Runic.Component, for: Jido.Exec.Node.Map do
  alias Jido.Exec.Node.Map

  def connectable?(_node, _other), do: true
  def connect(node, to, workflow), do: Map.connect(node, List.wrap(to), workflow)

  def source(node) do
    quote do
      Jido.Exec.Node.Map.new(
        id: unquote(Macro.escape(node.id)),
        name: unquote(node.name),
        component: unquote(node.component),
        collection: unquote(Macro.escape(node.collection)),
        instruction: unquote(Macro.escape(node.instruction)),
        params: unquote(Macro.escape(node.params)),
        on_error: unquote(node.on_error),
        location: unquote(Macro.escape(node.location))
      )
    end
  end

  def hash(node), do: node.hash
  def inputs(_node), do: [items: [type: :any, cardinality: :many]]
  def outputs(_node), do: [out: [type: :any]]
end
