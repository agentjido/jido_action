defmodule Jido.Flow.Builder do
  @moduledoc """
  Builds a Flow from runtime data.

  Each node has an explicit name. References use that name through `result/2`.
  `build/1` uses the same canonical constructor as the Flow module DSL
  and stored Flow decoder.

  Builder expressions are static data. For a Flow that must round-trip through
  stored Map or JSON data, use references, scalar literals, maps, and proper
  lists. Put executable computation in an Action. Low-level canonical Flow
  values can contain some static BEAM terms that the stored format rejects.

  Treat the Builder struct fields as internal. Use the functions in this
  module to create and update a Builder.
  """

  import Kernel, except: [in: 2, not: 1]

  alias Jido.Flow.Builder.Normalizer
  alias Jido.Flow.{Condition, Constructor, Ref}

  @common_node_options [:after, :deps, :meta, :provenance]
  @node_options %{
    step: @common_node_options,
    choice: @common_node_options,
    map: @common_node_options ++ [:on_error],
    reduce: @common_node_options,
    iterate: @common_node_options ++ [:completion, :while, :until, :repeat, :max_iterations]
  }

  @type expression ::
          Ref.t()
          | nil
          | boolean()
          | number()
          | String.t()
          | atom()
          | [expression()]
          | %{optional(term()) => expression()}
          | tuple()
  @type condition :: Condition.t()
  @type choice_option :: map()
  @type choice_fallback :: map()

  @opaque t :: %__MODULE__{
            config: map(),
            reversed_node_specs: [map()],
            return: expression() | nil
          }

  @enforce_keys [:config, :reversed_node_specs, :return]
  defstruct [:config, :reversed_node_specs, :return]

  @doc "Starts a Builder with Flow metadata."
  @spec new(map() | keyword()) :: t()
  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs),
      do: new(Map.new(attrs)),
      else: raise(ArgumentError, "invalid Flow metadata")
  end

  def new(%{} = attrs),
    do: %__MODULE__{config: attrs, reversed_node_specs: [], return: nil}

  @doc "Builds and validates the canonical Flow."
  @spec build(t()) :: {:ok, Jido.Flow.t()} | {:error, Exception.t()}
  def build(%__MODULE__{} = builder) do
    node_specs = Enum.reverse(builder.reversed_node_specs)

    with {:ok, node_specs} <- Normalizer.normalize(node_specs) do
      builder.config
      |> Map.drop([:node_specs, :reversed_node_specs, :nodes, :return])
      |> Map.put(:nodes, node_specs)
      |> Map.put(:return, builder.return)
      |> Constructor.build()
    end
  end

  @doc "Builds a Flow input reference."
  @spec input(term()) :: Ref.t()
  def input(path \\ []), do: Ref.input(path)

  @doc "Builds a runtime context reference."
  @spec context(term()) :: Ref.t()
  def context(path \\ []), do: Ref.context(path)

  @doc """
  Wraps one static literal value.

  Use scalar values, maps, and proper lists when the Flow must use stored Map
  or JSON data. Stored Flow data does not support tuples or other BEAM-only
  values.
  """
  @spec value(term()) :: Ref.t()
  def value(value), do: Ref.value(value)

  @doc "Builds a named node result reference."
  @spec result(atom() | String.t(), term()) :: Ref.t()
  def result(node, path \\ []), do: Ref.result(node, path)

  @doc "Appends a path to a reference."
  @spec select(Ref.t(), term()) :: Ref.t()
  def select(%Ref{} = source, path) do
    %{source | path: source.path ++ Ref.normalize_path(path)}
  end

  @doc "Builds a scoped Map or Reduce item reference."
  @spec item(term()) :: Ref.t()
  def item(path \\ nil), do: Ref.item(path)

  @doc "Builds a scoped collection item index reference."
  @spec item_index() :: Ref.t()
  def item_index, do: Ref.item_index()

  @doc "Builds a scoped collection item identifier reference."
  @spec item_id() :: Ref.t()
  def item_id, do: Ref.item_id()

  @doc "Builds a scoped Reduce accumulator reference."
  @spec accumulator(term()) :: Ref.t()
  def accumulator(path \\ nil), do: Ref.accumulator(path)

  @doc "Builds a scoped Iterator state reference."
  @spec state(term()) :: Ref.t()
  def state(path \\ nil), do: Ref.state(path)

  @doc "Builds a scoped Iterator index reference."
  @spec iteration_index() :: Ref.t()
  def iteration_index, do: Ref.iteration_index()

  @doc "Builds a scoped Iterator body result reference."
  @spec body_result(term()) :: Ref.t()
  def body_result(path \\ nil), do: Ref.body_result(path)

  @doc "Builds an equality condition."
  def eq(left, right), do: condition(:eq, [left, right])

  @doc "Builds an inequality condition."
  def neq(left, right), do: condition(:neq, [left, right])

  @doc "Builds a less-than condition."
  def lt(left, right), do: condition(:lt, [left, right])

  @doc "Builds a less-than-or-equal condition."
  def lte(left, right), do: condition(:lte, [left, right])

  @doc "Builds a greater-than condition."
  def gt(left, right), do: condition(:gt, [left, right])

  @doc "Builds a greater-than-or-equal condition."
  def gte(left, right), do: condition(:gte, [left, right])

  @doc "Builds a membership condition."
  def unquote(:in)(left, right), do: condition(:in, [left, right])

  @doc "Builds a condition that requires all child conditions."
  def all(conditions), do: condition(:all, conditions)

  @doc "Builds a condition that requires one child condition."
  def any(conditions), do: condition(:any, conditions)

  @doc "Builds an inverted condition."
  def not child, do: condition(:not, [child])

  @doc "Builds one named Choice option."
  @spec option(atom() | String.t(), condition(), module(), expression()) :: choice_option()
  def option(name, condition, action, input \\ %{}) do
    %{name: name, condition: condition, action: action, input: input}
  end

  @doc "Builds the required Choice fallback."
  @spec fallback(module(), expression()) :: choice_fallback()
  def fallback(action, input \\ %{}), do: %{action: action, input: input}

  @doc "Adds one named Action step."
  @spec step(t(), atom() | String.t(), module(), expression(), keyword()) :: t()
  def step(%__MODULE__{} = builder, name, action, input, opts \\ []) do
    add_node(builder, :step, %{name: name, action: action, input: input}, opts)
  end

  @doc "Adds one named Map node."
  @spec map(t(), atom() | String.t(), expression(), module(), expression(), keyword()) :: t()
  def map(%__MODULE__{} = builder, name, collection, action, input, opts \\ []) do
    add_node(
      builder,
      :map,
      %{name: name, collection: collection, action: action, input: input},
      opts
    )
  end

  @doc "Adds one named Reduce node."
  @spec reduce(
          t(),
          atom() | String.t(),
          expression(),
          expression(),
          module(),
          expression(),
          keyword()
        ) :: t()
  def reduce(%__MODULE__{} = builder, name, collection, initial, action, input, opts \\ []) do
    add_node(
      builder,
      :reduce,
      %{name: name, collection: collection, initial: initial, action: action, input: input},
      opts
    )
  end

  @doc "Adds one named, bounded Iterator node."
  @spec iterate(t(), atom() | String.t(), module(), expression(), map() | keyword(), keyword()) ::
          t()
  def iterate(%__MODULE__{} = builder, name, action, input, state, opts \\ []) do
    add_node(builder, :iterate, %{name: name, action: action, input: input, state: state}, opts)
  end

  @doc "Adds one named ordered Choice node."
  @spec choice(t(), atom() | String.t(), [choice_option()], choice_fallback(), keyword()) :: t()
  def choice(%__MODULE__{} = builder, name, options, fallback, opts \\ []) do
    add_node(builder, :choice, %{name: name, options: options, fallback: fallback}, opts)
  end

  @doc "Sets the Flow output expression."
  @spec return(t(), expression()) :: t()
  def return(%__MODULE__{} = builder, expression), do: %{builder | return: expression}

  defp add_node(builder, kind, attrs, opts) do
    spec = Map.put(attrs, :kind, kind)

    spec =
      case normalize_options(opts, kind) do
        {:ok, options} -> Map.merge(spec, options)
        {:error, error} -> Map.put(spec, :__builder_options_error__, error)
      end

    %{builder | reversed_node_specs: [spec | builder.reversed_node_specs]}
  end

  defp normalize_options(opts, kind) when is_list(opts) do
    if Keyword.keyword?(opts) and Enum.uniq(Keyword.keys(opts)) == Keyword.keys(opts) do
      options = Map.new(opts)
      allowed = Map.fetch!(@node_options, kind)
      unsupported = options |> Map.keys() |> Enum.reject(&Enum.member?(allowed, &1))

      case Enum.sort(unsupported) do
        [] -> {:ok, options}
        keys -> {:error, %{reason: :unsupported, options: keys}}
      end
    else
      {:error, %{reason: :invalid, options: opts}}
    end
  end

  defp normalize_options(opts, _kind), do: {:error, %{reason: :invalid, options: opts}}

  defp condition(operator, operands), do: %Condition{operator: operator, operands: operands}
end
