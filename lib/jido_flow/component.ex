defmodule Jido.Flow.Component do
  @moduledoc "Canonical component types and common field validation."

  alias Jido.Action
  alias Jido.Flow.Error
  alias Jido.Flow.Data
  alias Jido.Flow.Choice
  alias Jido.Flow.Dispatch
  alias Jido.Flow.Iterate
  alias Jido.Flow.Map, as: FlowMap
  alias Jido.Flow.Reduce
  alias Jido.Flow.Step
  alias Jido.Flow.Subflow

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
  def new(%Step{} = step), do: Step.new(step)
  def new(%Subflow{} = subflow), do: Subflow.new(subflow)
  def new(%Choice{} = choice), do: Choice.new(choice)
  def new(%FlowMap{} = map), do: FlowMap.new(map)
  def new(%Reduce{} = reduce), do: Reduce.new(reduce)
  def new(%Iterate{} = iterate), do: Iterate.new(iterate)
  def new(%Dispatch{} = dispatch), do: Dispatch.new(dispatch)

  def new(value) do
    {:error, Error.validation_error("expected a canonical Flow component", %{value: value})}
  end

  @doc false
  @spec name_of(t()) :: String.t()
  def name_of(%Step{name: name}), do: name
  def name_of(%Subflow{name: name}), do: name
  def name_of(%Choice{name: name}), do: name
  def name_of(%FlowMap{name: name}), do: name
  def name_of(%Reduce{name: name}), do: name
  def name_of(%Iterate{name: name}), do: name
  def name_of(%Dispatch{name: name}), do: name

  @doc false
  @spec kind(t()) :: :step | :subflow | :choice | :map | :reduce | :iterate | :dispatch
  def kind(%Step{}), do: :step
  def kind(%Subflow{}), do: :subflow
  def kind(%Choice{}), do: :choice
  def kind(%FlowMap{}), do: :map
  def kind(%Reduce{}), do: :reduce
  def kind(%Iterate{}), do: :iterate
  def kind(%Dispatch{}), do: :dispatch

  @doc false
  @spec needs_of(t()) :: [String.t()]
  def needs_of(%Step{needs: needs}), do: needs
  def needs_of(%Subflow{needs: needs}), do: needs
  def needs_of(%Choice{needs: needs}), do: needs
  def needs_of(%FlowMap{needs: needs}), do: needs
  def needs_of(%Reduce{needs: needs}), do: needs
  def needs_of(%Iterate{needs: needs}), do: needs
  def needs_of(%Dispatch{needs: needs}), do: needs

  @doc false
  @spec reference_dependencies(t()) :: [String.t()]
  def reference_dependencies(%Step{} = step),
    do: Step.result_refs(step) |> Enum.uniq() |> Enum.sort()

  def reference_dependencies(%Subflow{} = subflow),
    do: Subflow.result_refs(subflow) |> Enum.uniq() |> Enum.sort()

  def reference_dependencies(%Choice{} = choice), do: Choice.result_deps(choice)
  def reference_dependencies(%FlowMap{} = map), do: FlowMap.result_deps(map)
  def reference_dependencies(%Reduce{} = reduce), do: Reduce.result_deps(reduce)

  def reference_dependencies(%Iterate{} = iterate),
    do: Iterate.result_refs(iterate) |> Enum.uniq() |> Enum.sort()

  def reference_dependencies(%Dispatch{} = dispatch), do: Dispatch.result_deps(dispatch)

  @doc false
  @spec effective_dependencies(t()) :: [String.t()]
  def effective_dependencies(component) do
    (needs_of(component) ++ reference_dependencies(component)) |> Enum.uniq() |> Enum.sort()
  end

  @doc false
  @spec to_map(t()) :: map()
  def to_map(%Step{} = step) do
    %{
      kind: :step,
      name: step.name,
      action: step.action,
      params: Jido.Flow.Expression.to_map(step.params),
      needs: step.needs,
      meta: step.meta
    }
  end

  def to_map(%Subflow{} = subflow) do
    %{
      kind: :subflow,
      name: subflow.name,
      flow: subflow.flow,
      params: Jido.Flow.Expression.to_map(subflow.params),
      needs: subflow.needs,
      meta: subflow.meta
    }
  end

  def to_map(%Choice{} = choice), do: Choice.to_map(choice)
  def to_map(%FlowMap{} = map), do: FlowMap.to_map(map)
  def to_map(%Reduce{} = reduce), do: Reduce.to_map(reduce)

  def to_map(%Iterate{} = iterate) do
    %{
      kind: :iterate,
      name: iterate.name,
      action: iterate.action,
      params: Jido.Flow.Expression.to_map(iterate.params),
      state: %{
        schema: iterate.state.schema,
        initial: Jido.Flow.Expression.to_map(iterate.state.initial),
        update: Jido.Flow.Expression.to_map(iterate.state.update)
      },
      completion: Jido.Flow.Expression.to_map(iterate.completion),
      max_iterations: iterate.max_iterations,
      needs: iterate.needs,
      meta: iterate.meta
    }
  end

  def to_map(%Dispatch{} = dispatch), do: Dispatch.to_map(dispatch)

  @doc false
  @spec target_modules(t()) :: [module()]
  def target_modules(%Step{action: action}), do: [action]
  def target_modules(%Subflow{flow: flow}), do: [flow]

  def target_modules(%Choice{} = choice),
    do: Enum.map(choice.options, & &1.action) ++ [choice.fallback.action]

  def target_modules(%FlowMap{action: action}), do: [action]
  def target_modules(%Reduce{action: action}), do: [action]
  def target_modules(%Iterate{action: action}), do: [action]

  def target_modules(%Dispatch{decision: decision, expander: expander}),
    do: [decision, expander]

  @doc false
  @spec name(term()) :: {:ok, String.t()} | {:error, Exception.t()}
  def name(value) when is_atom(value) and not is_nil(value),
    do: value |> Atom.to_string() |> name()

  def name(value) when is_binary(value) do
    case Action.validate_name(value) do
      :ok -> {:ok, value}
      {:error, message} -> {:error, Error.validation_error(message)}
    end
  end

  def name(_value),
    do: {:error, Error.validation_error("component name must be a non-empty string")}

  @doc false
  @spec module(term(), String.t()) :: {:ok, module()} | {:error, Exception.t()}
  def module(value, _label) when is_atom(value) and not is_nil(value), do: {:ok, value}

  def module(_value, label) do
    {:error, Error.validation_error("#{label} must be a module atom")}
  end

  @doc false
  @spec needs_names(term()) :: {:ok, [String.t()]} | {:error, Exception.t()}
  def needs_names(nil), do: {:ok, []}

  def needs_names(values) when is_list(values) do
    if List.improper?(values) do
      {:error, Error.validation_error("component needs must be a proper list")}
    else
      values
      |> Enum.reduce_while({:ok, []}, fn value, {:ok, names} ->
        case name(value) do
          {:ok, name} ->
            {:cont, {:ok, [name | names]}}

          {:error, _error} ->
            {:halt,
             {:error, Error.validation_error("component needs must contain component names")}}
        end
      end)
      |> reject_duplicate_needs()
    end
  end

  def needs_names(_values), do: {:error, Error.validation_error("component needs must be a list")}

  @doc false
  @spec meta(term()) :: {:ok, Data.object()} | {:error, Exception.t()}
  def meta(nil), do: {:ok, %{}}

  def meta(value) do
    case Data.validate_object(value) do
      :ok -> {:ok, value}
      {:error, error} -> {:error, error}
    end
  end

  defp reject_duplicate_needs({:ok, reversed_names}) do
    names = Enum.reverse(reversed_names)

    case names -- Enum.uniq(names) do
      [] ->
        {:ok, names}

      [name | _] ->
        {:error, Error.validation_error("component needs contains a duplicate", %{name: name})}
    end
  end

  defp reject_duplicate_needs(error), do: error
end
