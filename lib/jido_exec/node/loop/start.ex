defmodule Jido.Exec.Node.Loop.Start do
  @moduledoc false

  alias Runic.Identity

  @enforce_keys [:id, :name, :hash, :loop]
  defstruct [:id, :name, :hash, :loop]

  @type t :: %__MODULE__{}

  @doc false
  @spec new(Jido.Exec.Node.Loop.t()) :: t()
  def new(%Jido.Exec.Node.Loop{} = loop) do
    id = {loop.id, :start}

    %__MODULE__{
      id: id,
      name: "__jido_#{loop.kind}__/#{loop.name}/start",
      hash:
        Identity.digest(:component_definition, %{
          kind: "jido_loop_start",
          version: 1,
          id: inspect(id)
        }),
      loop: loop
    }
  end
end

defimpl Runic.Identity.Projectable, for: Jido.Exec.Node.Loop.Start do
  def identity_document(node) do
    %{kind: :jido_loop_start, version: 1, id: inspect(node.id)}
  end
end

defimpl Runic.Workflow.Invokable, for: Jido.Exec.Node.Loop.Start do
  alias Jido.Exec.Node.Loop
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
    with {:ok, value, loop} <-
           Loop.start(node.loop, Jido.Exec.Fact.value(fact), context.run_context),
         :ok <- Jido.Exec.Portable.validate(value, :output, context.run_context),
         :ok <- Jido.Exec.Portable.validate(%{jido_loop: loop}, :metadata, context.run_context) do
      result =
        Jido.Exec.Fact.child(
          fact,
          [value: value, ancestry: {node.hash, fact.hash}, meta: %{jido_loop: loop}],
          context.run_context
        )

      Runnable.complete(runnable, result, [
        FactProduced.new(result, producer_label: :produced, weight: context.ancestry_depth + 1),
        %ActivationConsumed{fact_hash: fact.hash, node_hash: node.hash, from_label: :runnable}
      ])
    else
      {:error, error} ->
        Runnable.fail(
          runnable,
          Jido.Exec.Source.attach(error, node.loop.location, %{
            node: node.loop.component,
            node_path: node.loop.node_path
          })
        )
    end
  end
end

defimpl Runic.Component, for: Jido.Exec.Node.Loop.Start do
  def connectable?(_node, _other), do: true
  def connect(node, to, workflow), do: Runic.Workflow.add_step(workflow, to, node)

  def source(node) do
    quote do
      Jido.Exec.Node.Loop.Start.new(unquote(Macro.escape(node.loop)))
    end
  end

  def hash(node), do: node.hash
  def inputs(_node), do: [in: [type: :any]]
  def outputs(_node), do: [out: [type: :any]]
end
