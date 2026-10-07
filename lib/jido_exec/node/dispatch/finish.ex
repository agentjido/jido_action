defmodule Jido.Exec.Node.Dispatch.Finish do
  @moduledoc false

  alias Runic.Identity

  @enforce_keys [:id, :name, :hash, :dispatch_name, :component, :target_component]
  defstruct [:id, :name, :hash, :dispatch_name, :component, :target_component]

  @type t :: %__MODULE__{}

  @doc false
  @spec new(Jido.Exec.Node.Dispatch.t(), term()) :: t()
  def new(%Jido.Exec.Node.Dispatch{} = dispatch, target_id) do
    id = {dispatch.id, :finish, target_id}

    %__MODULE__{
      id: id,
      name: "__jido_dispatch__/#{dispatch.name}/finish/#{target_id}",
      hash:
        Identity.digest(:component_definition, %{
          kind: "jido_dispatch_finish",
          version: 1,
          id: inspect(id)
        }),
      dispatch_name: dispatch.name,
      component: dispatch.component,
      target_component: Jido.Exec.Node.Dispatch.target_component_key(dispatch)
    }
  end

  @doc false
  @spec finish(t(), term()) :: {:ok, term()} | {:error, term()}
  def finish(
        %__MODULE__{} = _node,
        {:jido_dispatch_target_result, frame, component, output, effects}
      ) do
    {:ok, Jido.Exec.Frame.put_result(frame, component, output, effects)}
  end

  def finish(%__MODULE__{} = node, frame) do
    with {:ok, frame} <- Jido.Exec.Frame.merge(frame),
         {:ok, output} <- Jido.Exec.Frame.fetch_result(frame, node.target_component) do
      prior = Jido.Exec.Frame.effects_for(frame, node.component)
      target_effects = Jido.Exec.Frame.effects_for(frame, node.target_component)
      {:ok, Jido.Exec.Frame.put_result(frame, node.component, output, prior ++ target_effects)}
    end
  end
end

defimpl Runic.Identity.Projectable, for: Jido.Exec.Node.Dispatch.Finish do
  def identity_document(node) do
    %{kind: :jido_dispatch_finish, version: 1, id: inspect(node.id)}
  end
end

defimpl Runic.Workflow.Invokable, for: Jido.Exec.Node.Dispatch.Finish do
  alias Jido.Exec.Node.Dispatch.Finish
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
    case Finish.finish(node, fact.value) do
      {:ok, value} ->
        result = Fact.new(value: value, ancestry: {node.hash, fact.hash})

        Runnable.complete(runnable, result, [
          FactProduced.new(result, producer_label: :produced, weight: context.ancestry_depth + 1),
          %ActivationConsumed{fact_hash: fact.hash, node_hash: node.hash, from_label: :runnable}
        ])

      {:error, error} ->
        Runnable.fail(runnable, error)
    end
  end
end

defimpl Runic.Workflow.Activator, for: Jido.Exec.Node.Dispatch.Finish do
  alias Jido.Exec.Node.Output
  alias Runic.Workflow
  alias Runic.Workflow.Events.RunnableActivated
  alias Runic.Workflow.{Fact, Invokable, Runnable}

  def activate_downstream(node, workflow, %Runnable{result: %Fact{} = fact}) do
    dispatch = Workflow.get_component(workflow, node.dispatch_name)

    events =
      workflow
      |> Workflow.next_steps(dispatch)
      |> Enum.filter(&match?(%Output{}, &1))
      |> Enum.map(fn successor ->
        %RunnableActivated{
          fact_hash: fact.hash,
          node_hash: successor.hash,
          activation_kind: activation_kind(successor)
        }
      end)

    updated = Enum.reduce(events, workflow, fn event, acc -> Workflow.apply_event(acc, event) end)
    {updated, events}
  end

  defp activation_kind(node) do
    case Invokable.match_or_execute(node) do
      :match -> :matchable
      :execute -> :runnable
    end
  end
end

defimpl Runic.Component, for: Jido.Exec.Node.Dispatch.Finish do
  def connectable?(_node, _other), do: true
  def connect(node, to, workflow), do: Runic.Workflow.add_step(workflow, to, node)

  def source(node) do
    quote do
      %Jido.Exec.Node.Dispatch.Finish{
        id: unquote(Macro.escape(node.id)),
        name: unquote(node.name),
        hash: unquote(Macro.escape(node.hash)),
        dispatch_name: unquote(node.dispatch_name),
        component: unquote(node.component),
        target_component: unquote(node.target_component)
      }
    end
  end

  def hash(node), do: node.hash
  def inputs(_node), do: [in: [type: :any]]
  def outputs(_node), do: [out: [type: :any]]
end
