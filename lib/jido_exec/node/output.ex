defmodule Jido.Exec.Node.Output do
  @moduledoc false

  alias Jido.Exec.{Frame, ValueResolver}
  alias Runic.Identity

  @enforce_keys [:id, :name, :hash, :output, :effect_order]
  defstruct [
    :id,
    :name,
    :hash,
    :output,
    :effect_order,
    :parent_component,
    :validator,
    :location
  ]

  @type t :: %__MODULE__{
          id: term(),
          name: atom() | String.t(),
          hash: Identity.t(),
          output: term(),
          effect_order: [String.t()],
          parent_component: String.t() | nil,
          validator: module() | Jido.Flow.t() | nil
        }

  @doc false
  @spec new(keyword()) :: t()
  def new(opts) do
    opts =
      Keyword.validate!(opts, [
        :id,
        :name,
        :output,
        :effect_order,
        :parent_component,
        :validator,
        :location
      ])

    id = Keyword.fetch!(opts, :id)
    name = Keyword.fetch!(opts, :name)
    output = Keyword.fetch!(opts, :output)
    effect_order = Keyword.fetch!(opts, :effect_order)

    hash =
      Identity.digest(:component_definition, %{
        kind: "jido_flow_output",
        version: 1,
        id: inspect(id)
      })

    %__MODULE__{
      id: id,
      name: name,
      hash: hash,
      output: output,
      effect_order: effect_order,
      parent_component: Keyword.get(opts, :parent_component),
      validator: Keyword.get(opts, :validator),
      location: Keyword.get(opts, :location)
    }
  end

  @doc false
  @spec resolve(t(), term(), map()) :: {:ok, term(), [term()]} | {:error, Exception.t()}
  def resolve(%__MODULE__{} = node, input, context) do
    with {:ok, frame} <- Frame.merge(input),
         {:ok, output} <- ValueResolver.resolve(node.output, Frame.resolver_state(frame, context)),
         {:ok, output} <- validate_output(node.validator, output) do
      effects = Frame.effects(frame, node.effect_order)
      complete_output(node, frame, output, effects)
    end
  end

  defp complete_output(%__MODULE__{parent_component: nil}, _frame, output, effects),
    do: {:ok, output, effects}

  defp complete_output(
         %__MODULE__{parent_component: component},
         {:jido_nested_flow_frame, 1, _parent, _child} = frame,
         output,
         effects
       ) do
    {:ok, Frame.complete_nested(frame, component, output, effects), []}
  end

  defp complete_output(%__MODULE__{} = node, frame, _output, _effects) do
    {:error,
     Jido.Flow.Error.execution_error("nested Flow output has no parent frame", %{
       node: node.parent_component,
       reason: :invalid_nested_flow_frame,
       frame: frame
     })}
  end

  defp validate_output(nil, output), do: {:ok, output}
  defp validate_output(module, output) when is_atom(module), do: module.validate_output(output)

  defp validate_output(%Jido.Flow{}, %Jido.Action.Output{} = output),
    do: Jido.Action.Output.validate(output)

  # Data and stored Flows follow the same map rule as Flow modules.
  defp validate_output(%Jido.Flow{} = flow, output) do
    details = %{module: Jido.Flow, flow: flow.name, context: "Flow output"}

    with {:ok, validated} <-
           Jido.Action.Validation.open_validate(flow.output_schema, output, details) do
      if is_map(validated) do
        {:ok, validated}
      else
        {:error,
         Jido.Action.Error.validation_error(
           "Action output validation must return a map",
           Map.put(details, :value, validated)
         )}
      end
    end
  end
end

defimpl Runic.Identity.Projectable, for: Jido.Exec.Node.Output do
  def identity_document(node) do
    %{kind: :jido_flow_output, version: 1, id: inspect(node.id)}
  end
end

defimpl Runic.Workflow.Invokable, for: Jido.Exec.Node.Output do
  alias Jido.Exec.Node.Output
  alias Runic.Workflow
  alias Runic.Workflow.{CausalContext, Fact, HookRunner, Runnable}
  alias Runic.Workflow.Events.{ActivationConsumed, FactProduced}

  def match_or_execute(_node), do: :execute

  def invoke(%Output{} = node, workflow, fact) do
    {:ok, runnable} = prepare(node, workflow, fact)
    executed = execute(node, runnable)
    Workflow.apply_runnable(workflow, executed)
  end

  def prepare(%Output{} = node, %Workflow{} = workflow, %Fact{} = fact) do
    context =
      CausalContext.new(
        node_hash: node.hash,
        input_fact: fact,
        ancestry_depth: Workflow.ancestry_depth(workflow, fact),
        hooks: Workflow.get_hooks(workflow, node.hash),
        run_context: Workflow.get_run_context(workflow, node.name)
      )

    {:ok, Runnable.new(node, fact, context)}
  end

  def execute(%Output{} = node, %Runnable{input_fact: fact, context: context} = runnable) do
    with {:ok, before_apply_fns} <- HookRunner.run_before(context, node, fact),
         {:ok, output, effects} <- Output.resolve(node, fact.value, context.run_context) do
      result_fact =
        Fact.new(
          value: output,
          ancestry: {node.hash, fact.hash},
          meta: %{jido: %{effects: effects}}
        )

      case HookRunner.run_after(context, node, fact, result_fact) do
        {:ok, after_apply_fns} ->
          events = [
            FactProduced.new(result_fact,
              producer_label: :produced,
              weight: context.ancestry_depth + 1
            ),
            %ActivationConsumed{
              fact_hash: fact.hash,
              node_hash: node.hash,
              from_label: :runnable
            }
          ]

          Runnable.complete(
            runnable,
            result_fact,
            events,
            before_apply_fns ++ after_apply_fns
          )

        {:error, reason} ->
          Runnable.fail(runnable, {:hook_error, reason})
      end
    else
      {:error, reason} ->
        phase = if is_nil(node.parent_component), do: :flow_output, else: :subflow_output
        Runnable.fail(runnable, Jido.Exec.Source.attach(reason, node.location, %{phase: phase}))
    end
  end
end

defimpl Runic.Component, for: Jido.Exec.Node.Output do
  alias Jido.Exec.Node.Output
  alias Runic.Workflow

  def connectable?(_node, _other), do: true

  def connect(%Output{} = node, to, workflow) when is_list(to) do
    join = to |> Enum.map(& &1.hash) |> Runic.Workflow.Join.new()
    workflow = Enum.reduce(to, workflow, &Workflow.add_step(&2, &1, join))

    workflow
    |> Workflow.add_step(join, node)
    |> register(node)
  end

  def connect(%Output{} = node, to, workflow) do
    workflow
    |> Workflow.add_step(to, node)
    |> register(node)
  end

  def source(%Output{} = node) do
    quote do
      Jido.Exec.Node.Output.new(
        id: unquote(Macro.escape(node.id)),
        name: unquote(node.name),
        output: unquote(Macro.escape(node.output)),
        effect_order: unquote(Macro.escape(node.effect_order)),
        parent_component: unquote(node.parent_component),
        validator: unquote(Macro.escape(node.validator)),
        location: unquote(Macro.escape(node.location))
      )
    end
  end

  def hash(%Output{hash: hash}), do: hash
  def inputs(_node), do: [in: [type: :any, doc: "Flow frame"]]
  def outputs(_node), do: [out: [type: :any, doc: "Flow output"]]

  defp register(workflow, node) do
    workflow
    |> Workflow.draw_connection(node, node, :component_of, properties: %{kind: :flow_output})
    |> Workflow.register_component(node)
  end
end
