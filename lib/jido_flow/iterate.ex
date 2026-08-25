defmodule Jido.Flow.Iterate do
  @moduledoc """
  A bounded local loop in a canonical Flow.

  Create it with `new/1`, the Flow module DSL, `Jido.Flow.Builder`, or
  `Jido.Flow.Codec`. An Iterate uses local state and stops when its completion
  condition is true. It fails when it reaches `max_iterations` first.
  """

  alias Jido.Action
  alias Jido.Flow.Error
  alias Jido.Flow.Component
  alias Jido.Flow.Condition
  alias Jido.Flow.Expression

  @maximum_iterations 10_000
  @keys [:name, :action, :params, :state, :completion, :max_iterations, :after, :meta]

  @schema Zoi.struct(
            __MODULE__,
            %{
              name: Zoi.string(description: "Component name"),
              action: Zoi.atom(description: "Iteration Action module"),
              params: Zoi.any(description: "Iteration parameter expression") |> Zoi.default(%{}),
              state: Zoi.any(description: "Local Iterate state data"),
              completion: Zoi.any(description: "Completion condition"),
              max_iterations: Zoi.integer(description: "Maximum iterations"),
              after:
                Zoi.list(Zoi.string(), description: "Explicit control order") |> Zoi.default([]),
              meta: Zoi.map(description: "Portable author metadata") |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  defmodule State do
    @moduledoc "Static state data for one `Jido.Flow.Iterate` component."

    alias Jido.Action
    alias Jido.Flow.Error
    alias Jido.Flow.Expression

    @schema Zoi.struct(
              __MODULE__,
              %{
                schema: Zoi.any(description: "Local state schema") |> Zoi.default([]),
                initial: Zoi.any(description: "Initial state expression"),
                update: Zoi.any(description: "State update expression")
              },
              coerce: true
            )

    @type t :: unquote(Zoi.type_spec(@schema))

    @enforce_keys Zoi.Struct.enforce_keys(@schema)
    defstruct Zoi.Struct.struct_fields(@schema)

    @doc "Builds and validates canonical Iterate state data."
    @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, Exception.t()}
    def new(%__MODULE__{} = state), do: state |> Map.from_struct() |> new()

    def new(attrs) when is_list(attrs),
      do: if(Keyword.keyword?(attrs), do: new(Map.new(attrs)), else: invalid())

    def new(%{} = attrs) do
      with :ok <- known_keys(attrs),
           {:ok, schema} <- schema(Map.get(attrs, :schema, [])),
           {:ok, initial} <- expression(attrs, :initial, :iterate_initial),
           {:ok, update} <- expression(attrs, :update, :iterate_update) do
        {:ok, %__MODULE__{schema: schema, initial: initial, update: update}}
      end
    end

    def new(_attrs), do: invalid()

    @doc "Builds canonical Iterate state data or raises its validation error."
    @spec new!(map() | keyword() | t()) :: t() | no_return()
    def new!(attrs) do
      case new(attrs) do
        {:ok, state} -> state
        {:error, error} -> raise error
      end
    end

    @doc false
    @spec result_refs(t()) :: [String.t()]
    def result_refs(%__MODULE__{} = state),
      do: Expression.result_refs(state.initial) ++ Expression.result_refs(state.update)

    defp known_keys(attrs) do
      case Enum.find(Map.keys(attrs), &(&1 not in [:schema, :initial, :update])) do
        nil -> :ok
        key -> {:error, Error.validation_error("unknown iterate state key: #{inspect(key)}")}
      end
    end

    defp schema(value) do
      with :ok <- Action.validate_static_data(value),
           :ok <- Action.validate_action_schema(value) do
        {:ok, value}
      else
        {:error, message} -> {:error, Error.validation_error("iterate state schema #{message}")}
      end
    end

    defp expression(attrs, field, scope) do
      if Map.has_key?(attrs, field) do
        value = Map.fetch!(attrs, field)

        with {:ok, value} <- Expression.normalize(value),
             :ok <- Expression.validate(value, scope) do
          {:ok, value}
        end
      else
        {:error, Error.validation_error("iterate state #{field} is required", %{path: [field]})}
      end
    end

    defp invalid, do: {:error, Error.validation_error("iterate state must be a map")}
  end

  @doc "Builds and validates one canonical Iterate component."
  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, Exception.t()}
  def new(%__MODULE__{} = iterate), do: iterate |> Map.from_struct() |> new()

  def new(attrs) when is_list(attrs),
    do: if(Keyword.keyword?(attrs), do: new(Map.new(attrs)), else: invalid())

  def new(%{} = attrs) do
    with :ok <- known_keys(attrs),
         {:ok, name} <- Component.name(Map.get(attrs, :name)),
         {:ok, action} <- Component.module(Map.get(attrs, :action), "iterate action"),
         {:ok, params} <- expression(Map.get(attrs, :params, %{}), :iterate_params),
         {:ok, state} <- state(Map.get(attrs, :state)),
         {:ok, completion} <- completion(Map.get(attrs, :completion)),
         {:ok, maximum} <- maximum(Map.get(attrs, :max_iterations)),
         {:ok, after_names} <- Component.after_names(Map.get(attrs, :after, [])),
         {:ok, meta} <- Component.meta(Map.get(attrs, :meta, %{})) do
      {:ok,
       %__MODULE__{
         name: name,
         action: action,
         params: params,
         state: state,
         completion: completion,
         max_iterations: maximum,
         after: after_names,
         meta: meta
       }}
    end
  end

  def new(_attrs), do: invalid()

  @doc "Builds one canonical Iterate component or raises its validation error."
  @spec new!(map() | keyword() | t()) :: t() | no_return()
  def new!(attrs) do
    case new(attrs) do
      {:ok, iterate} -> iterate
      {:error, error} -> raise error
    end
  end

  @doc false
  @spec result_refs(t()) :: [String.t()]
  def result_refs(%__MODULE__{} = iterate) do
    Expression.result_refs(iterate.params) ++
      State.result_refs(iterate.state) ++
      Condition.result_deps(iterate.completion)
  end

  defp known_keys(attrs) do
    case Enum.find(Map.keys(attrs), &(&1 not in @keys)) do
      nil -> :ok
      key -> {:error, Error.validation_error("unknown iterate key: #{inspect(key)}")}
    end
  end

  defp expression(value, scope) do
    with {:ok, value} <- Expression.normalize(value),
         :ok <- Expression.validate(value, scope) do
      {:ok, value}
    end
  end

  defp state(nil), do: {:error, Error.validation_error("iterate state is required")}
  defp state(value), do: State.new(value)

  defp completion(%Condition{} = value), do: Condition.validate(value, :iterate_completion)
  defp completion(_value), do: {:error, Error.validation_error("iterate completion is required")}

  defp maximum(value) when is_integer(value) and value in 1..@maximum_iterations, do: {:ok, value}

  defp maximum(_value),
    do: {:error, Error.validation_error("iterate max_iterations must be from 1 to 10000")}

  defp invalid, do: {:error, Error.validation_error("iterate configuration must be a map")}
end
