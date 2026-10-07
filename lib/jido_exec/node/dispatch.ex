defmodule Jido.Exec.Node.Dispatch do
  @moduledoc false

  alias Jido.Exec.Frame
  alias Jido.Exec.Node.Action
  alias Jido.Exec.Node.Dispatch.Finish
  alias Jido.Instruction
  alias Runic.Identity
  alias Runic.Workflow

  @enforce_keys [
    :id,
    :name,
    :hash,
    :component,
    :decision,
    :decision_params,
    :expander
  ]
  defstruct [
    :id,
    :name,
    :hash,
    :component,
    :decision,
    :decision_params,
    :expander,
    :location
  ]

  @type t :: %__MODULE__{}

  @doc false
  @spec new(keyword()) :: t()
  def new(opts) do
    opts =
      Keyword.validate!(opts, [
        :id,
        :name,
        :component,
        :decision,
        :decision_params,
        :expander,
        :location
      ])

    id = Keyword.fetch!(opts, :id)

    %__MODULE__{
      id: id,
      name: Keyword.fetch!(opts, :name),
      hash:
        Identity.digest(:component_definition, %{
          kind: "jido_dispatch",
          version: 1,
          id: inspect(id)
        }),
      component: Keyword.fetch!(opts, :component),
      decision: Keyword.fetch!(opts, :decision),
      decision_params: Keyword.fetch!(opts, :decision_params),
      expander: Keyword.fetch!(opts, :expander),
      location: Keyword.get(opts, :location)
    }
  end

  @doc false
  @spec connect(t(), [term()], Workflow.t()) :: Workflow.t()
  def connect(%__MODULE__{} = node, parents, %Workflow{} = workflow) do
    decision = action(node, :decision, node.decision, node.decision_params)
    expander = action(node, :expander, node.expander, nil)

    workflow
    |> connect_from(parents, decision)
    |> Workflow.add_step(decision, expander)
    |> Workflow.add_step(expander, node)
    |> Workflow.draw_connection(node, node, :component_of, properties: %{kind: :dispatch})
    |> Workflow.register_component(node)
  end

  @doc false
  @spec expand(Workflow.t(), t(), term(), term()) :: Workflow.t()
  def expand(workflow, node, target, input) do
    with {:ok, instruction} <- Instruction.resolve(target) do
      case instruction do
        %Instruction{kind: :action} ->
          add_action_target(workflow, node, instruction, input)

        %Instruction{kind: :flow} ->
          add_flow_target(workflow, node, instruction, input)
      end
    else
      {:error, error} -> raise error
    end
  end

  @doc false
  @spec finish(term()) :: {:ok, term()} | {:continue, term()}
  def finish({:jido_dispatch_finish, frame, component, output, effects}) do
    {:ok, Frame.put_result(frame, component, output, effects)}
  end

  def finish({:jido_dispatch_continue, _frame, _component, _input, _target, _effects} = value),
    do: {:continue, value}

  @doc false
  @spec target_component_key(t()) :: String.t()
  def target_component_key(%__MODULE__{} = node) do
    "__jido_dispatch_target__/#{node.component}"
  end

  defp action(node, phase, instruction, params) do
    metadata = %{
      jido_flow: %{
        component: node.component,
        mode: {:dispatch, phase, node},
        params: params,
        location: node.location
      }
    }

    {:ok, instruction} = Instruction.bind(instruction, %{}, %{}, metadata)

    Action.new(instruction,
      id: {node.id, phase},
      name: internal_name(node, Atom.to_string(phase))
    )
  end

  defp add_action_target(workflow, node, instruction, input) do
    metadata = %{
      jido_flow: %{
        component: node.component,
        mode: {:dispatch, :target, node},
        params: input,
        location: node.location
      }
    }

    {:ok, instruction} = Instruction.bind(instruction, %{}, %{}, metadata)
    target_id = target_id(node, instruction.target)

    target =
      Action.new(instruction,
        id: {node.id, :target, target_id},
        name: internal_name(node, "target/#{target_id}")
      )

    finish = Finish.new(node, target_id)

    workflow
    |> Workflow.add(target, to: node)
    |> Workflow.add(finish, to: target)
  end

  defp add_flow_target(workflow, node, instruction, input) do
    target_id = target_id(node, instruction.target)
    target_key = target_component_key(node)

    base_name = internal_name(node, "target/#{target_id}")

    target =
      Jido.Exec.Compiler.compile_nested!(instruction,
        namespace: base_name,
        boundary_name: base_name,
        parent_component: target_key,
        input_params: input,
        boundary_location: node.location
      )

    finish = Finish.new(node, target_id)

    workflow
    |> Workflow.add(target, to: node)
    |> Workflow.add(finish,
      connections: [[from: {target.name, :result}, to: :in]]
    )
  end

  defp target_id(node, target) do
    Identity.digest(:component_definition, %{
      kind: "jido_dispatch_target",
      version: 1,
      dispatch: inspect(node.id),
      target: inspect(target)
    })
    |> to_string()
  end

  defp connect_from(workflow, [], child), do: Workflow.add_step(workflow, child)
  defp connect_from(workflow, [parent], child), do: Workflow.add_step(workflow, parent, child)
  defp connect_from(workflow, parents, child), do: Workflow.add_step(workflow, parents, child)

  defp internal_name(node, suffix), do: "__jido_dispatch__/#{node.name}/#{suffix}"
end

defimpl Runic.Identity.Projectable, for: Jido.Exec.Node.Dispatch do
  def identity_document(node) do
    %{kind: :jido_dispatch, version: 1, id: inspect(node.id)}
  end
end

defimpl Runic.Workflow.Invokable, for: Jido.Exec.Node.Dispatch do
  alias Jido.Exec.Frame
  alias Jido.Exec.Node.Dispatch
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
    case Dispatch.finish(fact.value) do
      {:ok, value} ->
        complete(runnable, node, fact, value, %{}, context, [])

      {:continue, {:jido_dispatch_continue, frame, component, input, target, effects}} ->
        apply_fn = fn workflow -> Dispatch.expand(workflow, node, target, input) end
        value = Frame.put_result(frame, component, nil, effects)
        complete(runnable, node, fact, value, %{jido_dispatch: :continue}, context, [apply_fn])
    end
  rescue
    error -> Runnable.fail(runnable, error)
  catch
    kind, reason -> Runnable.fail(runnable, {kind, reason})
  end

  defp complete(runnable, node, fact, value, meta, context, apply_fns) do
    result = Fact.new(value: value, ancestry: {node.hash, fact.hash}, meta: meta)

    Runnable.complete(
      runnable,
      result,
      [
        FactProduced.new(result, producer_label: :produced, weight: context.ancestry_depth + 1),
        %ActivationConsumed{fact_hash: fact.hash, node_hash: node.hash, from_label: :runnable}
      ],
      apply_fns
    )
  end
end

defimpl Runic.Workflow.Activator, for: Jido.Exec.Node.Dispatch do
  alias Jido.Exec.Node.{Dispatch, Output}
  alias Runic.Workflow
  alias Runic.Workflow.Events.RunnableActivated
  alias Runic.Workflow.{Fact, Invokable, Runnable}

  def activate_downstream(node, workflow, %Runnable{result: %Fact{} = fact}) do
    successors = Workflow.next_steps(workflow, node)

    selected =
      if Map.get(fact.meta, :jido_dispatch) == :continue do
        Enum.reject(successors, &match?(%Output{}, &1))
      else
        Enum.filter(successors, &match?(%Output{}, &1))
      end

    events =
      Enum.map(selected, fn successor ->
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

defimpl Runic.Component, for: Jido.Exec.Node.Dispatch do
  alias Jido.Exec.Node.Dispatch

  def connectable?(_node, _other), do: true
  def connect(node, to, workflow), do: Dispatch.connect(node, List.wrap(to), workflow)

  def source(node) do
    quote do
      Jido.Exec.Node.Dispatch.new(
        id: unquote(Macro.escape(node.id)),
        name: unquote(node.name),
        component: unquote(node.component),
        decision: unquote(Macro.escape(node.decision)),
        decision_params: unquote(Macro.escape(node.decision_params)),
        expander: unquote(Macro.escape(node.expander)),
        location: unquote(Macro.escape(node.location))
      )
    end
  end

  def hash(node), do: node.hash
  def inputs(_node), do: [in: [type: :any]]
  def outputs(_node), do: [out: [type: :any]]
end
