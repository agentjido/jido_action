defmodule Jido.Flow.Builder do
  @moduledoc """
  Builds a canonical `Jido.Flow` from runtime data.

  The Builder stores canonical component structs. `step/5` resolves its target
  through `Jido.Executable` and stores a Step or Subflow. Other component
  Action fields are Action-only and are checked by executable validation.
  """

  import Kernel, except: [in: 2, not: 1]

  alias Jido.Executable
  alias Jido.Flow
  alias Jido.Flow.Error
  alias Jido.Flow.Choice
  alias Jido.Flow.Condition
  alias Jido.Flow.Iterate
  alias Jido.Flow.Map, as: FlowMap
  alias Jido.Flow.Reduce
  alias Jido.Flow.Ref
  alias Jido.Flow.Step
  alias Jido.Flow.Subflow

  @type expression :: Jido.Flow.Data.t() | Ref.t()
  @type condition :: Condition.t()
  @type choice_option :: Choice.Option.t() | map()
  @type choice_fallback :: Choice.Fallback.t() | map()

  @opaque t :: %__MODULE__{
            config: map(),
            reversed_components: [Jido.Flow.Component.t()],
            output: expression() | nil,
            error: Exception.t() | nil
          }

  @enforce_keys [:config, :reversed_components, :output, :error]
  defstruct [:config, :reversed_components, :output, :error]

  @doc "Starts a Builder with Flow metadata."
  @spec new(map() | keyword()) :: t()
  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs),
      do: new(Map.new(attrs)),
      else: %__MODULE__{
        config: %{},
        reversed_components: [],
        output: nil,
        error: invalid("Flow metadata must be a map")
      }
  end

  def new(%{} = attrs) do
    %__MODULE__{config: attrs, reversed_components: [], output: nil, error: nil}
  end

  def new(_attrs) do
    %__MODULE__{
      config: %{},
      reversed_components: [],
      output: nil,
      error: invalid("Flow metadata must be a map")
    }
  end

  @doc "Builds and validates the canonical Flow."
  @spec build(t()) :: {:ok, Flow.t()} | {:error, Exception.t()}
  def build(%__MODULE__{error: %_{} = error}), do: {:error, error}

  def build(%__MODULE__{} = builder) do
    builder.config
    |> Map.put(:components, Enum.reverse(builder.reversed_components))
    |> Map.put(:output, builder.output)
    |> Flow.new()
  end

  @doc "Builds a Flow input reference."
  def input(path \\ []), do: Ref.input(path)

  @doc "Builds a runtime context reference."
  def context(path \\ []), do: Ref.context(path)

  @doc "Returns one literal unchanged."
  def value(value), do: value

  @doc "Builds a named component result reference."
  def result(component, path \\ []), do: Ref.result(component, path)

  @doc "Appends a path to a reference."
  def select(%Ref{} = source, path) do
    %{source | path: source.path ++ Ref.normalize_path(path)}
  end

  @doc "Builds a scoped Map or Reduce item reference."
  def item(path \\ nil), do: Ref.item(path)

  @doc "Builds a scoped collection item index reference."
  def item_index, do: Ref.item_index()

  @doc "Builds a scoped collection item identifier reference."
  def item_id, do: Ref.item_id()

  @doc "Builds a scoped Reduce accumulator reference."
  def accumulator(path \\ nil), do: Ref.accumulator(path)

  @doc "Builds a scoped Iterate state reference."
  def state(path \\ nil), do: Ref.state(path)

  @doc "Builds a scoped Iterate index reference."
  def iteration_index, do: Ref.iteration_index()

  @doc "Builds a scoped Iterate body result reference."
  def body_result(path \\ nil), do: Ref.body_result(path)

  @doc "Builds an equality condition."
  def eq(left, right), do: Condition.eq(left, right)

  @doc "Builds an inequality condition."
  def neq(left, right), do: Condition.neq(left, right)

  @doc "Builds a less-than condition."
  def lt(left, right), do: Condition.lt(left, right)

  @doc "Builds a less-than-or-equal condition."
  def lte(left, right), do: Condition.lte(left, right)

  @doc "Builds a greater-than condition."
  def gt(left, right), do: Condition.gt(left, right)

  @doc "Builds a greater-than-or-equal condition."
  def gte(left, right), do: Condition.gte(left, right)

  @doc "Builds a membership condition."
  def unquote(:in)(left, right), do: Condition.in(left, right)

  @doc "Builds a condition that requires all child conditions."
  def all(conditions), do: Condition.all(conditions)

  @doc "Builds a condition that requires one child condition."
  def any(conditions), do: Condition.any(conditions)

  @doc "Builds an inverted condition."
  def not condition, do: Condition.not(condition)

  @doc "Builds one named Choice option."
  def option(name, condition, action, params \\ %{}) do
    %{name: name, condition: condition, action: action, params: params}
  end

  @doc "Builds the required Choice fallback."
  def fallback(action, params \\ %{}), do: %{action: action, params: params}

  @doc "Adds one named Action Step or derived Subflow."
  def step(%__MODULE__{} = builder, name, target, params, opts \\ []) do
    with {:ok, common} <- common_options(opts),
         {:ok, executable} <- Executable.resolve(target),
         {:ok, component} <- step_component(executable.kind, name, target, params, common) do
      append(builder, component)
    else
      {:error, error} -> fail(builder, normalize_error(error))
    end
  end

  @doc "Adds one named Map component."
  def map(%__MODULE__{} = builder, name, collection, action, params, opts \\ []) do
    with {:ok, options} <- options(opts, [:after, :meta, :on_error]),
         {:ok, component} <-
           FlowMap.new(
             options
             |> Map.merge(%{name: name, collection: collection, action: action, params: params})
           ) do
      append(builder, component)
    else
      {:error, error} -> fail(builder, normalize_error(error))
    end
  end

  @doc "Adds one named Reduce component."
  def reduce(%__MODULE__{} = builder, name, collection, initial, action, params, opts \\ []) do
    with {:ok, common} <- common_options(opts),
         {:ok, component} <-
           Reduce.new(
             Map.merge(common, %{
               name: name,
               collection: collection,
               initial: initial,
               action: action,
               params: params
             })
           ) do
      append(builder, component)
    else
      {:error, error} -> fail(builder, normalize_error(error))
    end
  end

  @doc "Adds one named bounded Iterate component."
  def iterate(%__MODULE__{} = builder, name, action, params, state, opts \\ []) do
    with {:ok, options} <- options(opts, [:after, :meta, :completion, :max_iterations]),
         {:ok, component} <-
           Iterate.new(
             options
             |> Map.merge(%{name: name, action: action, params: params, state: state})
           ) do
      append(builder, component)
    else
      {:error, error} -> fail(builder, normalize_error(error))
    end
  end

  @doc "Adds one named ordered Choice component."
  def choice(%__MODULE__{} = builder, name, choices, fallback, opts \\ []) do
    with {:ok, common} <- common_options(opts),
         {:ok, component} <-
           Choice.new(Map.merge(common, %{name: name, options: choices, fallback: fallback})) do
      append(builder, component)
    else
      {:error, error} -> fail(builder, normalize_error(error))
    end
  end

  @doc "Sets the required Flow output expression."
  def output(%__MODULE__{} = builder, expression), do: %{builder | output: expression}

  defp step_component(:action, name, target, params, common) do
    Step.new(Map.merge(common, %{name: name, action: target, params: params}))
  end

  defp step_component(:flow, name, target, params, common) do
    Subflow.new(Map.merge(common, %{name: name, flow: target, params: params}))
  end

  defp common_options(opts), do: options(opts, [:after, :meta])

  defp options(opts, allowed) when is_list(opts) do
    if Keyword.keyword?(opts) and Enum.uniq(Keyword.keys(opts)) == Keyword.keys(opts) do
      values = Map.new(opts)

      case values |> Map.keys() |> Enum.reject(&Enum.member?(allowed, &1)) |> Enum.sort() do
        [] ->
          {:ok, values}

        fields ->
          {:error, invalid("Builder options contain unsupported fields", %{fields: fields})}
      end
    else
      {:error, invalid("Builder options must be a keyword list without duplicate fields")}
    end
  end

  defp options(_opts, _allowed), do: {:error, invalid("Builder options must be a keyword list")}

  defp append(%__MODULE__{error: nil} = builder, component) do
    %{builder | reversed_components: [component | builder.reversed_components]}
  end

  defp append(builder, _component), do: builder

  defp fail(%__MODULE__{error: nil} = builder, error), do: %{builder | error: error}
  defp fail(builder, _error), do: builder

  defp normalize_error(error) when is_exception(error) do
    if Error.owned?(error) do
      error
    else
      details = error |> Map.get(:details, %{}) |> Map.put(:cause, error.__struct__)
      Error.validation_error(Exception.message(error), details)
    end
  end

  defp normalize_error(reason),
    do: invalid("Builder could not resolve its target", %{reason: reason})

  defp invalid(message, details \\ %{}), do: Error.validation_error(message, details)
end
