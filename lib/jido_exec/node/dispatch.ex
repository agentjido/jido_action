defmodule Jido.Exec.Node.Dispatch do
  @moduledoc false

  require Runic

  alias Jido.Exec.Frame
  alias Jido.Exec.Node.Action
  alias Jido.Exec.Node.Dispatch.Finish
  alias Jido.Instruction
  alias Runic.Identity
  alias Runic.Workflow
  alias Runic.Workflow.{Call, ChildInvocation}

  @enforce_keys [
    :id,
    :name,
    :hash,
    :component,
    :decision,
    :expander
  ]
  defstruct [
    :id,
    :name,
    :hash,
    :component,
    :decision,
    :expander,
    :location,
    :node_path
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
        :expander,
        :location,
        :node_path
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
      expander: Keyword.fetch!(opts, :expander),
      location: Keyword.get(opts, :location),
      node_path: Keyword.get(opts, :node_path, [Keyword.fetch!(opts, :component)])
    }
  end

  @doc false
  @spec connect(t(), [term()], Workflow.t()) :: Workflow.t()
  def connect(%__MODULE__{} = node, parents, %Workflow{} = workflow) do
    decision = action(node, :decision, node.decision, node.decision.params)
    expander = action(node, :expander, node.expander, nil)

    workflow
    |> connect_from(parents, decision)
    |> Workflow.add_step(decision, expander)
    |> Workflow.add_step(expander, node)
    |> Workflow.add_step(node, finished_condition(node))
    |> Workflow.register_component(finished_condition(node))
    |> Workflow.draw_connection(node, node, :component_of, properties: %{kind: :dispatch})
    |> Workflow.register_component(node)
  end

  @doc """
  Returns the Condition that passes finished Dispatch frames to the Flow output.

  A continued Dispatch stores a `nil` result until its selected target finishes.
  """
  @spec finished_condition(t()) :: Runic.Workflow.Condition.t()
  def finished_condition(%__MODULE__{} = node),
    do: finished_condition(node.id, node.name, node.component)

  @doc false
  @spec finished_condition(term(), term(), String.t()) :: Runic.Workflow.Condition.t()
  def finished_condition(id, name, component) do
    source =
      quote do
        Jido.Exec.Node.Dispatch.finished_condition(
          unquote(Macro.escape(id)),
          unquote(name),
          unquote(component)
        )
      end

    %Runic.Workflow.Condition{
      name: internal_name(%{name: name}, "finished"),
      hash:
        Identity.digest(:component_definition, %{
          kind: "jido_dispatch_finished",
          version: 1,
          id: inspect(id)
        }),
      work: fn value -> finished?(value, component) end,
      arity: 1,
      closure: Runic.Closure.new(source, %{}, nil),
      meta_refs: []
    }
  end

  @doc false
  @spec finished?(term(), String.t()) :: boolean()
  def finished?(%ChildInvocation{}, _component), do: false

  def finished?(value, component) do
    case Frame.fetch_result(value, component) do
      {:ok, nil} -> false
      {:ok, _output} -> true
      :error -> false
    end
  end

  @doc false
  @spec expansion(t(), term(), term(), term(), map()) ::
          {term(), (Workflow.t() -> Workflow.t())} | no_return()
  def expansion(node, target, input, frame, runtime \\ %{}) do
    case Instruction.resolve(target) do
      {:ok, %Instruction{kind: :action} = instruction} ->
        action_target(node, instruction, input, frame)

      {:ok, %Instruction{kind: :flow} = instruction} ->
        {frame, flow_target(node, instruction, input, runtime)}

      {:error, %{details: details} = error} when is_map(details) ->
        raise %{
          error
          | details:
              Map.merge(details, %{
                node: node.component,
                node_path: node.node_path,
                phase: :dispatch
              })
        }
    end
  end

  @doc false
  @spec finish(term()) :: {:ok, term()} | {:continue, term()} | {:handoff, term()}
  def finish({:jido_dispatch_handoff, frame, component, request, effects}) do
    {:handoff, Frame.put_result(frame, component, request, effects)}
  end

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

  defp action(node, phase, instruction, params, target_id \\ nil) do
    flow = %{
      component: node.component,
      mode: {:dispatch, phase},
      params: params,
      location: node.location,
      node_path: node.node_path
    }

    instruction =
      case instruction do
        %Instruction{} ->
          {:ok, bound} = Instruction.bind(instruction, %{}, %{})
          bound

        call ->
          call
      end

    id = if target_id, do: {node.id, phase, target_id}, else: {node.id, phase}
    suffix = if target_id, do: "#{phase}/#{target_id}", else: Atom.to_string(phase)

    Action.new(instruction, flow: flow, id: id, name: internal_name(node, suffix))
  end

  defp action_target(node, instruction, input, frame) do
    target_id = target_id(node, instruction.target)

    target = action(node, :target, instruction, input, target_id)
    request = ChildInvocation.new(target: target, input: frame)

    call =
      Call.new(Runic.step(fn request -> request end),
        name: internal_name(node, "call/#{target_id}")
      )

    finish = Finish.new(node, target_id)

    apply_fn = fn workflow ->
      workflow
      |> Workflow.add(call, to: node)
      |> Workflow.add(finish, connections: [[from: {call.name, :out}, to: :in]])
    end

    {request, apply_fn}
  end

  defp flow_target(node, instruction, input, runtime) do
    target_id = target_id(node, instruction.target)
    target_key = target_component_key(node)

    base_name = internal_name(node, "target/#{target_id}")

    target =
      Jido.Exec.Compiler.compile_nested!(instruction,
        namespace: base_name,
        boundary_name: base_name,
        parent_component: target_key,
        input_params: input,
        boundary_location: node.location,
        node_path_prefix: node.node_path
      )

    case Jido.Exec.Node.Wait.validate_host(target, runtime) do
      :ok -> :ok
      {:error, error} -> raise error
    end

    finish = Finish.new(node, target_id)

    fn workflow ->
      workflow
      |> Workflow.add(target, to: node)
      |> Workflow.add(finish, connections: [[from: {target.name, :result}, to: :in]])
    end
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
        run_context: Workflow.get_run_context(workflow, node.name),
        ancestry_depth: Workflow.ancestry_depth(workflow, fact)
      )

    {:ok, Runnable.new(node, fact, context)}
  end

  def execute(node, %Runnable{input_fact: fact, context: context} = runnable) do
    case Dispatch.finish(Jido.Exec.Fact.value(fact)) do
      {:ok, value} ->
        complete(runnable, node, fact, value, context, [])

      {:handoff, value} ->
        complete(runnable, node, fact, value, context, [], %{jido: %{control: :handoff}})

      {:continue, {:jido_dispatch_continue, frame, component, input, target, effects}} ->
        frame = Frame.put_result(frame, component, nil, effects)
        {value, apply_fn} = Dispatch.expansion(node, target, input, frame, context.run_context)
        complete(runnable, node, fact, value, context, [apply_fn])
    end
  rescue
    error -> Runnable.fail(runnable, error)
  catch
    kind, reason -> Runnable.fail(runnable, {kind, reason})
  end

  defp complete(runnable, node, fact, value, context, apply_fns, meta \\ %{}) do
    result =
      Jido.Exec.Fact.child(fact, value: value, meta: meta, ancestry: {node.hash, fact.hash})

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
        expander: unquote(Macro.escape(node.expander)),
        location: unquote(Macro.escape(node.location)),
        node_path: unquote(Macro.escape(node.node_path))
      )
    end
  end

  def hash(node), do: node.hash
  def inputs(_node), do: [in: [type: :any]]
  def outputs(_node), do: [out: [type: :any]]
end
