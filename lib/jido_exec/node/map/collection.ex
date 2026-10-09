defmodule Jido.Exec.Node.Map.Collection do
  @moduledoc false

  alias Jido.Exec.{Frame, Portable, ValueResolver}
  alias Runic.Identity

  @enforce_keys [:id, :name, :hash, :component, :value, :params]
  defstruct [:id, :name, :hash, :component, :value, :params, :location, :node_path]

  @type t :: %__MODULE__{}

  @doc false
  @spec new(keyword()) :: t()
  def new(opts) do
    opts =
      Keyword.validate!(opts, [:id, :name, :component, :value, :params, :location, :node_path])

    id = Keyword.fetch!(opts, :id)

    %__MODULE__{
      id: id,
      name: Keyword.fetch!(opts, :name),
      hash:
        Identity.digest(:component_definition, %{
          kind: "jido_map_collection",
          version: 1,
          id: id
        }),
      component: Keyword.fetch!(opts, :component),
      value: Keyword.fetch!(opts, :value),
      params: Keyword.fetch!(opts, :params),
      location: Keyword.get(opts, :location),
      node_path: Keyword.get(opts, :node_path, [Keyword.fetch!(opts, :component)])
    }
  end

  @doc false
  @spec resolve(t(), term(), term()) :: {:ok, [term()]} | {:error, term()}
  def resolve(%__MODULE__{} = node, input, context) do
    with {:ok, frame} <- Frame.merge(input),
         {:ok, collection} <-
           ValueResolver.resolve(node.value, Frame.resolver_state(frame, context)),
         {:ok, items} <- enumerable(collection) do
      state = Frame.resolver_state(frame, context)

      # Items carry only their resolved params. The frame rides on the first
      # item so fact size stays linear in the collection size.
      values =
        case items do
          [] ->
            [{:jido_map_empty, frame, node.component}]

          items ->
            items
            |> Enum.with_index()
            |> Enum.map(fn {item, index} ->
              item_id = Frame.item_id(node.id, index)
              item_state = Map.merge(state, %{item: item, item_index: index, item_id: item_id})
              params = resolve_params(node.params, item_state)
              {:jido_map_item, index, item_id, params, if(index == 0, do: frame)}
            end)
        end

      case Portable.validate(values, :output, context) do
        :ok -> {:ok, values}
        {:error, _} = error -> error
      end
    end
  end

  defp resolve_params(params, state) do
    case ValueResolver.resolve(params, state) do
      {:error, error} -> {:error, Jido.Flow.Error.to_map(error)}
      result -> result
    end
  end

  defp enumerable(value) do
    if is_nil(Enumerable.impl_for(value)) do
      {:error, ArgumentError.exception("Map collection is not enumerable")}
    else
      {:ok, Enum.to_list(value)}
    end
  end
end

defimpl Runic.Identity.Projectable, for: Jido.Exec.Node.Map.Collection do
  def identity_document(node) do
    %{kind: :jido_map_collection, version: 1, id: inspect(node.id)}
  end
end

defimpl Runic.Workflow.Invokable, for: Jido.Exec.Node.Map.Collection do
  alias Jido.Exec.Node.Map.Collection
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
    case Collection.resolve(node, Jido.Exec.Fact.value(fact), context.run_context) do
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

defimpl Runic.Component, for: Jido.Exec.Node.Map.Collection do
  def connectable?(_node, _other), do: true
  def connect(node, to, workflow), do: Runic.Workflow.add_step(workflow, to, node)

  def source(node) do
    quote do
      Jido.Exec.Node.Map.Collection.new(
        id: unquote(Macro.escape(node.id)),
        name: unquote(node.name),
        component: unquote(node.component),
        value: unquote(Macro.escape(node.value)),
        params: unquote(Macro.escape(node.params)),
        location: unquote(Macro.escape(node.location)),
        node_path: unquote(Macro.escape(node.node_path))
      )
    end
  end

  def hash(node), do: node.hash
  def inputs(_node), do: [in: [type: :any]]
  def outputs(_node), do: [out: [type: :any, cardinality: :many]]
end
