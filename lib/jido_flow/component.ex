defmodule Jido.Flow.Component do
  @moduledoc "Canonical component types and common field validation."

  alias Jido.Flow.Component.Fields
  alias Jido.Flow.Error
  alias Jido.Flow.Data
  alias Jido.Flow.Choice
  alias Jido.Flow.Dispatch
  alias Jido.Flow.Iterate
  alias Jido.Flow.Map, as: FlowMap
  alias Jido.Flow.Reduce
  alias Jido.Flow.Step
  alias Jido.Flow.Subflow

  @components [
    step: Step,
    subflow: Subflow,
    choice: Choice,
    map: FlowMap,
    reduce: Reduce,
    iterate: Iterate,
    dispatch: Dispatch
  ]
  @component_modules Keyword.values(@components)
  @component_modules_by_kind Map.new(@components)
  @component_kinds Map.new(@components, fn {kind, module} -> {module, kind} end)

  @type t ::
          Jido.Flow.Step.t()
          | Jido.Flow.Subflow.t()
          | Jido.Flow.Choice.t()
          | Jido.Flow.Map.t()
          | Jido.Flow.Reduce.t()
          | Jido.Flow.Iterate.t()
          | Jido.Flow.Dispatch.t()

  @doc false
  @spec new(term()) :: {:ok, t()} | {:error, Exception.t()}
  def new(%{__struct__: module} = component) when module in @component_modules do
    apply(module, :new, [component])
  end

  def new(%{kind: kind} = attrs) when not is_struct(attrs) do
    case Map.fetch(@component_modules_by_kind, kind) do
      {:ok, module} -> apply(module, :new, [Map.delete(attrs, :kind)])
      :error -> invalid_component(attrs)
    end
  end

  def new(value), do: invalid_component(value)

  defp invalid_component(value) do
    {:error, Error.validation_error("expected a canonical Flow component", %{value: value})}
  end

  @doc false
  @spec name_of(t()) :: String.t()
  def name_of(%{__struct__: module, name: name}) when module in @component_modules, do: name

  @doc false
  @spec kind(t()) :: :step | :subflow | :choice | :map | :reduce | :iterate | :dispatch
  def kind(%{__struct__: module}) when module in @component_modules,
    do: Map.fetch!(@component_kinds, module)

  @doc false
  @spec needs_of(t()) :: [String.t()]
  def needs_of(%{__struct__: module, needs: needs}) when module in @component_modules, do: needs

  @doc false
  @spec reference_dependencies(t()) :: [String.t()]
  def reference_dependencies(%{__struct__: module} = component)
      when module in @component_modules do
    component
    |> then(&apply(module, :result_refs, [&1]))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc false
  @spec effective_dependencies(t()) :: [String.t()]
  def effective_dependencies(component) do
    (needs_of(component) ++ reference_dependencies(component)) |> Enum.uniq() |> Enum.sort()
  end

  @doc false
  @spec to_map(t()) :: map()
  def to_map(%{__struct__: module} = component) when module in @component_modules,
    do: apply(module, :to_map, [component])

  @doc false
  @spec target_modules(t()) :: [module()]
  def target_modules(%{__struct__: module} = component) when module in @component_modules,
    do: apply(module, :target_modules, [component])

  @doc false
  @spec name(term()) :: {:ok, String.t()} | {:error, Exception.t()}
  defdelegate name(value), to: Fields

  @doc false
  @spec module(term(), String.t()) :: {:ok, module()} | {:error, Exception.t()}
  defdelegate module(value, label), to: Fields

  @doc false
  @spec needs_names(term()) :: {:ok, [String.t()]} | {:error, Exception.t()}
  defdelegate needs_names(values), to: Fields

  @doc false
  @spec meta(term()) :: {:ok, Data.object()} | {:error, Exception.t()}
  defdelegate meta(value), to: Fields
end
