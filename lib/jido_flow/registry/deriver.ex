defmodule Jido.Flow.Registry.Deriver do
  @moduledoc false

  alias Jido.Flow
  alias Jido.Flow.Choice
  alias Jido.Flow.Condition
  alias Jido.Flow.Iterate
  alias Jido.Flow.Map, as: FlowMap
  alias Jido.Flow.Reduce
  alias Jido.Flow.Ref
  alias Jido.Flow.Step
  alias Jido.Flow.Subflow

  @kinds [:action, :flow, :schema, :atom]
  @namespaces %{
    action: "actions",
    flow: "flows",
    schema: "schemas",
    atom: "atoms"
  }

  @doc false
  @spec entries(Flow.t()) :: %{String.t() => Jido.Flow.Registry.write_entry()}
  def entries(%Flow{} = flow) do
    values =
      empty_values()
      |> add(:schema, flow.schema)
      |> add(:schema, flow.output_schema)
      |> collect_components(flow.components)
      |> collect_expression(flow.output)

    Map.new(@kinds, fn kind -> {kind, sorted_values(values, kind)} end)
    |> Enum.flat_map(fn {kind, kind_values} ->
      kind_values
      |> Enum.with_index(1)
      |> Enum.map(fn {value, index} ->
        identifier = "#{Map.fetch!(@namespaces, kind)}/generated-#{index}"
        {identifier, {kind, value}}
      end)
    end)
    |> Map.new()
  end

  defp empty_values, do: Map.new(@kinds, &{&1, MapSet.new()})

  defp add(values, kind, value) do
    Map.update!(values, kind, &MapSet.put(&1, value))
  end

  defp sorted_values(values, kind) do
    values
    |> Map.fetch!(kind)
    |> MapSet.to_list()
    |> Enum.sort_by(&sort_key(kind, &1))
  end

  defp sort_key(kind, value) when kind in [:action, :flow, :atom], do: Atom.to_string(value)
  defp sort_key(:schema, value), do: :erlang.term_to_binary(value)

  defp collect_components(values, components) do
    Enum.reduce(components, values, &collect_component(&2, &1))
  end

  defp collect_component(values, %Step{} = step) do
    values
    |> add(:action, step.action)
    |> collect_expression(step.params)
    |> collect_data(step.meta)
  end

  defp collect_component(values, %Subflow{} = subflow) do
    values
    |> add(:flow, subflow.flow)
    |> collect_expression(subflow.params)
    |> collect_data(subflow.meta)
  end

  defp collect_component(values, %Choice{} = choice) do
    values =
      Enum.reduce(choice.options, values, fn option, values ->
        values
        |> add(:action, option.action)
        |> collect_condition(option.condition)
        |> collect_expression(option.params)
      end)

    values
    |> add(:action, choice.fallback.action)
    |> collect_expression(choice.fallback.params)
    |> collect_data(choice.meta)
  end

  defp collect_component(values, %FlowMap{} = map) do
    values
    |> add(:action, map.action)
    |> collect_expression(map.collection)
    |> collect_expression(map.params)
    |> collect_data(map.meta)
  end

  defp collect_component(values, %Reduce{} = reduce) do
    values
    |> add(:action, reduce.action)
    |> collect_expression(reduce.collection)
    |> collect_expression(reduce.initial)
    |> collect_expression(reduce.params)
    |> collect_data(reduce.meta)
  end

  defp collect_component(values, %Iterate{} = iterate) do
    values
    |> add(:action, iterate.action)
    |> add(:schema, iterate.state.schema)
    |> collect_expression(iterate.params)
    |> collect_expression(iterate.state.initial)
    |> collect_expression(iterate.state.update)
    |> collect_condition(iterate.completion)
    |> collect_data(iterate.meta)
  end

  defp collect_condition(values, %Condition{} = condition) do
    Enum.reduce(condition.operands, values, fn
      %Condition{} = condition, values -> collect_condition(values, condition)
      expression, values -> collect_expression(values, expression)
    end)
  end

  defp collect_expression(values, %Ref{} = ref), do: collect_data(values, ref.path)

  defp collect_expression(values, value) when is_list(value) do
    Enum.reduce(value, values, &collect_expression(&2, &1))
  end

  defp collect_expression(values, value) when is_map(value) and not is_struct(value) do
    Enum.reduce(value, values, fn {key, expression}, values ->
      values
      |> collect_data(key)
      |> collect_expression(expression)
    end)
  end

  defp collect_expression(values, value), do: collect_data(values, value)

  defp collect_data(values, value)
       when is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value),
       do: values

  defp collect_data(values, value) when is_atom(value), do: add(values, :atom, value)

  defp collect_data(values, value) when is_list(value) do
    Enum.reduce(value, values, &collect_data(&2, &1))
  end

  defp collect_data(values, value) when is_map(value) and not is_struct(value) do
    Enum.reduce(value, values, fn {key, item}, values ->
      values
      |> collect_data(key)
      |> collect_data(item)
    end)
  end
end
