defmodule Jido.Flow.Dynamic do
  @moduledoc """
  A bounded dynamic Action loop.

  A Dynamic component calls its decision Action, then its expander Action. A
  normal expander result completes the component. An expander continuation
  runs inside the current Flow and sends its effective result to the next
  decision call.
  """

  alias Jido.Flow.Component
  alias Jido.Flow.Error
  alias Jido.Flow.Expression

  @maximum_continuations 10_000
  @config_keys [:name, :decision, :expander, :params, :max_continuations, :after, :meta]

  @schema Zoi.struct(
            __MODULE__,
            %{
              name: Zoi.string(description: "Component name"),
              decision: Zoi.atom(description: "Decision Action module"),
              expander: Zoi.atom(description: "Expander Action module"),
              params: Zoi.any(description: "Initial parameter expression") |> Zoi.default(%{}),
              max_continuations: Zoi.integer(description: "Maximum local continuation cycles"),
              after:
                Zoi.list(Zoi.string(), description: "Explicit control order") |> Zoi.default([]),
              meta: Zoi.map(description: "Portable author metadata") |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Builds and validates one canonical Dynamic component."
  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, Exception.t()}
  def new(%__MODULE__{} = dynamic), do: dynamic |> Map.from_struct() |> new()

  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs), do: attrs |> Map.new() |> new(), else: invalid_configuration()
  end

  def new(%{} = attrs) do
    with :ok <- known_keys(attrs),
         {:ok, name} <- Component.name(Map.get(attrs, :name)),
         {:ok, decision} <- Component.module(Map.get(attrs, :decision), "dynamic decision"),
         {:ok, expander} <- Component.module(Map.get(attrs, :expander), "dynamic expander"),
         {:ok, params} <- expression(Map.get(attrs, :params, %{})),
         {:ok, max_continuations} <- max_continuations(Map.get(attrs, :max_continuations)),
         {:ok, after_names} <- Component.after_names(Map.get(attrs, :after, [])),
         {:ok, meta} <- Component.meta(Map.get(attrs, :meta, %{})) do
      {:ok,
       %__MODULE__{
         name: name,
         decision: decision,
         expander: expander,
         params: params,
         max_continuations: max_continuations,
         after: after_names,
         meta: meta
       }}
    end
  end

  def new(_attrs), do: invalid_configuration()

  @doc "Builds one canonical Dynamic component or raises its validation error."
  @spec new!(map() | keyword() | t()) :: t() | no_return()
  def new!(attrs) do
    case new(attrs) do
      {:ok, dynamic} -> dynamic
      {:error, error} -> raise error
    end
  end

  @doc false
  @spec result_deps(t()) :: [String.t()]
  def result_deps(%__MODULE__{} = dynamic) do
    dynamic.params |> Expression.result_refs() |> Enum.uniq() |> Enum.sort()
  end

  @doc false
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = dynamic) do
    %{
      kind: :dynamic,
      name: dynamic.name,
      decision: dynamic.decision,
      expander: dynamic.expander,
      params: Expression.to_map(dynamic.params),
      max_continuations: dynamic.max_continuations,
      after: dynamic.after,
      meta: dynamic.meta
    }
  end

  defp known_keys(attrs) do
    case Enum.find(Map.keys(attrs), &(&1 not in @config_keys)) do
      nil -> :ok
      key -> {:error, Error.validation_error("unknown dynamic key: #{inspect(key)}")}
    end
  end

  defp expression(value) do
    with {:ok, value} <- Expression.normalize(value),
         :ok <- Expression.validate(value, :flow) do
      {:ok, value}
    end
  end

  defp max_continuations(value)
       when is_integer(value) and value in 1..@maximum_continuations,
       do: {:ok, value}

  defp max_continuations(_value) do
    {:error,
     Error.validation_error("dynamic max_continuations must be from 1 to 10000", %{
       path: [:max_continuations]
     })}
  end

  defp invalid_configuration,
    do: {:error, Error.validation_error("dynamic configuration must be a map", %{path: []})}
end
