defmodule Jido.Flow.Element do
  @moduledoc false

  alias Jido.Flow.Choice
  alias Jido.Flow.Iterator
  alias Jido.Flow.Map, as: FlowMap
  alias Jido.Flow.Node
  alias Jido.Flow.Reduce

  @type t :: Node.t() | Choice.t() | FlowMap.t() | Reduce.t() | Iterator.t()

  @spec new(term()) :: {:ok, t()} | {:error, Exception.t()}
  def new(%Iterator{} = iterator), do: Iterator.new(iterator)
  def new(%FlowMap{} = map), do: FlowMap.new(map)
  def new(%Reduce{} = reduce), do: Reduce.new(reduce)
  def new(%Choice{} = choice), do: Choice.new(choice)
  def new(%Node{} = node), do: Node.new(node)

  def new(%{} = attrs) do
    case Map.get(attrs, :kind) do
      :iterate -> attrs |> Map.delete(:kind) |> Iterator.new()
      :map -> attrs |> Map.delete(:kind) |> FlowMap.new()
      :reduce -> attrs |> Map.delete(:kind) |> Reduce.new()
      _kind -> infer_legacy_variant(attrs)
    end
  end

  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs) do
      case Keyword.get(attrs, :kind) do
        :iterate -> attrs |> Keyword.delete(:kind) |> Iterator.new()
        :map -> attrs |> Keyword.delete(:kind) |> FlowMap.new()
        :reduce -> attrs |> Keyword.delete(:kind) |> Reduce.new()
        _kind -> infer_legacy_variant(attrs)
      end
    else
      Node.new(attrs)
    end
  end

  def new(attrs), do: Node.new(attrs)

  @doc false
  @spec kind(t()) :: :step | :choice | :map | :reduce | :iterate
  def kind(%Node{}), do: :step
  def kind(%Choice{}), do: :choice
  def kind(%FlowMap{}), do: :map
  def kind(%Reduce{}), do: :reduce
  def kind(%Iterator{}), do: :iterate

  @spec name(t()) :: String.t()
  def name(%Node{name: name}), do: name
  def name(%Choice{name: name}), do: name
  def name(%FlowMap{name: name}), do: name
  def name(%Reduce{name: name}), do: name
  def name(%Iterator{name: name}), do: name

  @spec result_deps(t()) :: [String.t()]
  def result_deps(%Node{} = node), do: Node.result_deps(node)
  def result_deps(%Choice{} = choice), do: Choice.result_deps(choice)
  def result_deps(%FlowMap{} = map), do: FlowMap.result_deps(map)
  def result_deps(%Reduce{} = reduce), do: Reduce.result_deps(reduce)
  def result_deps(%Iterator{} = iterator), do: Iterator.result_deps(iterator)

  @spec put_deps(t(), [String.t()]) :: t()
  def put_deps(%Node{} = node, deps), do: %{node | deps: deps}
  def put_deps(%Choice{} = choice, deps), do: Choice.put_deps(choice, deps)
  def put_deps(%FlowMap{} = map, deps), do: FlowMap.put_deps(map, deps)
  def put_deps(%Reduce{} = reduce, deps), do: Reduce.put_deps(reduce, deps)
  def put_deps(%Iterator{} = iterator, deps), do: Iterator.put_deps(iterator, deps)

  @spec deps(t()) :: [String.t()]
  def deps(%Node{deps: deps}), do: deps
  def deps(%Choice{deps: deps}), do: deps
  def deps(%FlowMap{deps: deps}), do: deps
  def deps(%Reduce{deps: deps}), do: deps
  def deps(%Iterator{deps: deps}), do: deps

  @spec check(t()) :: :ok | {:error, Exception.t()}
  def check(%Node{action: action, name: name}) do
    case Jido.Instruction.validate_action_contract(action) do
      :ok ->
        :ok

      {:error, error} ->
        {:error,
         Jido.Action.Error.validation_error(
           error.message,
           Map.merge(error.details, %{node: name, action: action})
         )}
    end
  end

  def check(%Choice{} = choice), do: Choice.check(choice)
  def check(%FlowMap{} = map), do: FlowMap.check(map)
  def check(%Reduce{} = reduce), do: Reduce.check(reduce)
  def check(%Iterator{} = iterator), do: Iterator.check(iterator)

  @spec target_modules(t()) :: [module()]
  def target_modules(%Node{action: action}), do: [action]
  def target_modules(%Choice{} = choice), do: choice |> Choice.targets() |> Enum.map(&elem(&1, 1))
  def target_modules(%FlowMap{action: action}), do: [action]
  def target_modules(%Reduce{action: action}), do: [action]
  def target_modules(%Iterator{action: action}), do: [action]

  @spec to_map(t(), keyword()) :: map()
  def to_map(element, opts \\ [])
  def to_map(%Node{} = node, opts), do: Node.to_map(node, opts)
  def to_map(%Choice{} = choice, opts), do: Choice.to_map(choice, opts)
  def to_map(%FlowMap{} = map, opts), do: FlowMap.to_map(map, opts)
  def to_map(%Reduce{} = reduce, opts), do: Reduce.to_map(reduce, opts)
  def to_map(%Iterator{} = iterator, opts), do: Iterator.to_map(iterator, opts)

  @spec static_data(t()) :: map()
  def static_data(%Node{} = node),
    do: %{name: node.name, action: node.action, input: node.input, deps: node.deps}

  def static_data(%Choice{} = choice), do: Choice.static_data(choice)
  def static_data(%FlowMap{} = map), do: FlowMap.static_data(map)
  def static_data(%Reduce{} = reduce), do: Reduce.static_data(reduce)
  def static_data(%Iterator{} = iterator), do: Iterator.static_data(iterator)

  @doc false
  @spec semantic_data(t()) :: map()
  def semantic_data(element), do: static_data(element)

  defp infer_legacy_variant(attrs) when is_map(attrs) do
    if Map.has_key?(attrs, :options) or Map.has_key?(attrs, :fallback) do
      Choice.new(attrs)
    else
      Node.new(attrs)
    end
  end

  defp infer_legacy_variant(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs) and
         (Keyword.has_key?(attrs, :options) or Keyword.has_key?(attrs, :fallback)) do
      Choice.new(attrs)
    else
      Node.new(attrs)
    end
  end
end
