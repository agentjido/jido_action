defmodule Jido.Exec.Node.Dispatch.Finish do
  @moduledoc false

  use Runic.Workflow.SingleOutput, batch_parent: false

  alias Runic.Identity
  alias Runic.Workflow.SingleOutput.{Context, Result}

  @enforce_keys [:id, :name, :hash, :dispatch_id, :dispatch_name, :component, :target_component]
  defstruct [:id, :name, :hash, :dispatch_id, :dispatch_name, :component, :target_component]

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
      dispatch_id: dispatch.id,
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

  @impl Runic.Workflow.SingleOutput
  @doc false
  @spec run(t(), term(), Context.t()) :: Result.t()
  def run(%__MODULE__{} = node, input, %Context{} = context) do
    case finish(node, Jido.Exec.Fact.unwrap(input)) do
      {:ok, value} -> Jido.Exec.Fact.result(input, context, value)
      {:error, error} -> Result.failure(error)
    end
  end
end

defimpl Runic.Identity.Projectable, for: Jido.Exec.Node.Dispatch.Finish do
  def identity_document(node) do
    %{kind: :jido_dispatch_finish, version: 1, id: inspect(node.id)}
  end
end

defimpl Runic.Component, for: Jido.Exec.Node.Dispatch.Finish do
  def connectable?(_node, _other), do: true
  # Connect to the Dispatch output Condition here, so durable replay keeps the edge.
  def connect(node, to, workflow) do
    workflow
    |> Runic.Workflow.add_step(to, node)
    |> Runic.Workflow.add_step(
      node,
      Jido.Exec.Node.Dispatch.finished_condition(
        node.dispatch_id,
        node.dispatch_name,
        node.component
      )
    )
  end

  def source(node) do
    quote do
      %Jido.Exec.Node.Dispatch.Finish{
        id: unquote(Macro.escape(node.id)),
        name: unquote(node.name),
        hash: unquote(Macro.escape(node.hash)),
        dispatch_id: unquote(Macro.escape(node.dispatch_id)),
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
