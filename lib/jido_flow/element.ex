defmodule Jido.Flow.Element do
  @moduledoc false

  alias Jido.Flow.Choice
  alias Jido.Flow.Node

  @type t :: Node.t() | Choice.t()

  @spec new(term()) :: {:ok, t()} | {:error, Exception.t()}
  def new(%Choice{} = choice), do: Choice.new(choice)
  def new(%Node{} = node), do: Node.new(node)

  def new(%{} = attrs) do
    if Map.has_key?(attrs, :options) or Map.has_key?(attrs, :fallback) do
      Choice.new(attrs)
    else
      Node.new(attrs)
    end
  end

  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs) and
         (Keyword.has_key?(attrs, :options) or Keyword.has_key?(attrs, :fallback)) do
      Choice.new(attrs)
    else
      Node.new(attrs)
    end
  end

  def new(attrs), do: Node.new(attrs)

  @spec name(t()) :: String.t()
  def name(%Node{name: name}), do: name
  def name(%Choice{name: name}), do: name

  @spec result_deps(t()) :: [String.t()]
  def result_deps(%Node{} = node), do: Node.result_deps(node)
  def result_deps(%Choice{} = choice), do: Choice.result_deps(choice)

  @spec put_deps(t(), [String.t()]) :: t()
  def put_deps(%Node{} = node, deps), do: %{node | deps: deps}
  def put_deps(%Choice{} = choice, deps), do: Choice.put_deps(choice, deps)

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

  @spec to_map(t(), keyword()) :: map()
  def to_map(element, opts \\ [])
  def to_map(%Node{} = node, opts), do: Node.to_map(node, opts)
  def to_map(%Choice{} = choice, opts), do: Choice.to_map(choice, opts)

  @spec semantic_data(t()) :: map()
  def semantic_data(%Node{} = node),
    do: %{name: node.name, action: node.action, input: node.input, deps: node.deps}

  def semantic_data(%Choice{} = choice), do: Choice.semantic_data(choice)
end
