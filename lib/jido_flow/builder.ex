defmodule Jido.Flow.Builder do
  @moduledoc """
  Builds a Flow from runtime data.

  Each node has an explicit name. References use that name through `result/2`.
  `build/1` uses the same canonical constructor as the declarative Spark DSL
  and stored Flow decoder.
  """

  import Kernel, except: [in: 2, not: 1]

  alias Jido.Action.Error
  alias Jido.Flow.{Condition, Constructor, Ref}

  @common_node_options [:after, :deps, :meta, :provenance]
  @node_options %{
    step: @common_node_options,
    choice: @common_node_options,
    map: @common_node_options ++ [:on_error],
    reduce: @common_node_options,
    iterate: @common_node_options ++ [:completion, :while, :until, :repeat, :max_iterations]
  }

  @type expression :: Ref.t() | map() | list() | term()
  @type condition :: Condition.t()
  @type choice_option :: map()
  @type choice_fallback :: map()

  @type t :: %__MODULE__{
          config: map(),
          node_specs: [map()],
          return: expression() | nil
        }

  @enforce_keys [:config, :node_specs, :return]
  defstruct [:config, :node_specs, :return]

  @doc "Starts a Builder with Flow metadata."
  @spec new(map() | keyword()) :: t()
  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs),
      do: new(Map.new(attrs)),
      else: raise(ArgumentError, "invalid Flow metadata")
  end

  def new(%{} = attrs), do: %__MODULE__{config: attrs, node_specs: [], return: nil}

  @doc "Builds and validates the canonical Flow."
  @spec build(t()) :: {:ok, Jido.Flow.t()} | {:error, Exception.t()}
  def build(%__MODULE__{} = builder) do
    with {:ok, node_specs} <- normalize_node_specs(builder.node_specs) do
      builder.config
      |> Map.drop([:node_specs, :nodes, :return])
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

  @doc "Wraps one literal value."
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

    %{builder | node_specs: builder.node_specs ++ [spec]}
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

  defp normalize_node_specs(specs) do
    specs
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {spec, index}, {:ok, normalized} ->
      case normalize_node_spec(spec) do
        {:ok, spec} -> {:cont, {:ok, [spec | normalized]}}
        {:error, error} -> {:halt, {:error, prefix_path(error, [:nodes, index])}}
      end
    end)
    |> reverse_ok()
  end

  defp normalize_node_spec(%{
         kind: kind,
         __builder_options_error__: %{reason: :unsupported, options: options}
       }) do
    {:error,
     Error.validation_error("Builder #{kind} received unsupported options", %{
       options: options,
       path: [:options]
     })}
  end

  defp normalize_node_spec(%{__builder_options_error__: error}) do
    {:error,
     Error.validation_error(
       "Builder node options must be a keyword list with unique keys",
       %{
         options: Map.get(error, :options),
         path: [:options]
       }
     )}
  end

  defp normalize_node_spec(%{kind: :iterate} = spec) do
    with {:ok, spec} <- normalize_common_aliases(spec),
         {:ok, state} <- normalize_state(Map.get(spec, :state)),
         {:ok, completion, max_iterations} <- normalize_termination(spec) do
      {:ok,
       spec
       |> Map.drop([:while, :until, :repeat])
       |> Map.put(:state, state)
       |> Map.put(:completion, completion)
       |> Map.put(:max_iterations, max_iterations)}
    end
  end

  defp normalize_node_spec(spec), do: normalize_common_aliases(spec)

  defp normalize_common_aliases(spec) do
    with {:ok, deps} <- normalize_after(Map.get(spec, :after, Map.get(spec, :deps, []))),
         {:ok, provenance} <- normalize_provenance(spec) do
      {:ok,
       spec
       |> Map.drop([:after, :meta])
       |> Map.put(:deps, deps)
       |> Map.put(:provenance, provenance)}
    end
  end

  defp normalize_state(%{__struct__: _module} = state), do: {:ok, state}

  defp normalize_state(%{} = state) do
    {:ok, Map.put_new(state, :update, Ref.body_result())}
  end

  defp normalize_state(state) when is_list(state) do
    if Keyword.keyword?(state),
      do: state |> Map.new() |> normalize_state(),
      else: {:error, Error.validation_error("iterator state configuration must be a map")}
  end

  defp normalize_state(state), do: {:ok, state}

  defp normalize_termination(%{completion: completion, max_iterations: max_iterations}) do
    {:ok, completion, max_iterations}
  end

  defp normalize_termination(spec) do
    forms = Enum.filter([:while, :until, :repeat], &Map.has_key?(spec, &1))

    case forms do
      [:until] ->
        termination_with_limit(Map.fetch!(spec, :until), Map.get(spec, :max_iterations))

      [:while] ->
        completion = %Condition{operator: :not, operands: [Map.fetch!(spec, :while)]}
        termination_with_limit(completion, Map.get(spec, :max_iterations))

      [:repeat] ->
        repeat_termination(Map.fetch!(spec, :repeat), Map.has_key?(spec, :max_iterations))

      _forms ->
        {:error,
         Error.validation_error("iterate requires exactly one of while, until, or repeat")}
    end
  end

  defp termination_with_limit(completion, max_iterations)
       when is_integer(max_iterations) and max_iterations >= 1 and max_iterations <= 10_000 do
    {:ok, completion, max_iterations}
  end

  defp termination_with_limit(_completion, _max_iterations) do
    {:error,
     Error.validation_error(
       "iterate max_iterations must be an integer from 1 to 10000",
       %{path: [:max_iterations]}
     )}
  end

  defp repeat_termination(_count, true) do
    {:error,
     Error.validation_error("iterate with repeat must not set max_iterations", %{
       path: [:max_iterations]
     })}
  end

  defp repeat_termination(count, false)
       when is_integer(count) and count >= 1 and count <= 10_000 do
    completion = %Condition{
      operator: :gte,
      operands: [Ref.iteration_index(), Ref.value(count)]
    }

    {:ok, completion, count}
  end

  defp repeat_termination(_count, false) do
    {:error,
     Error.validation_error(
       "iterate repeat count must be an integer from 1 to 10000",
       %{path: [:repeat]}
     )}
  end

  defp normalize_after(nil), do: {:ok, []}

  defp normalize_after(after_targets) when is_list(after_targets) do
    if List.improper?(after_targets) do
      {:error, Error.validation_error("flow node dependencies must be a proper list")}
    else
      {:ok, after_targets}
    end
  end

  defp normalize_after(after_target), do: {:ok, [after_target]}

  defp normalize_provenance(spec) do
    provenance = Map.get(spec, :provenance, Map.get(spec, :meta, %{}))

    if is_map(provenance) do
      {:ok, provenance}
    else
      {:error, Error.validation_error("flow node metadata must be a map", %{path: [:meta]})}
    end
  end

  defp reverse_ok({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_ok({:error, error}), do: {:error, error}

  defp prefix_path(%{details: details} = error, prefix) when is_map(details) do
    %{error | details: Map.put(details, :path, prefix ++ Map.get(details, :path, []))}
  end

  defp prefix_path(error, _prefix), do: error

  defp condition(operator, operands), do: %Condition{operator: operator, operands: operands}
end
