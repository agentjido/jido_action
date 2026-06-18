defmodule Jido.Flow.ComponentFactory do
  @moduledoc false

  require Runic

  alias Jido.Flow.Step

  @doc false
  def to_runic!(%{type: :step} = entry) do
    Step.new(entry.action, entry.params, name: entry.name, context: entry.context)
  end

  def to_runic!(%{type: :map} = entry) do
    mapper = entry.mapper

    Runic.map(
      fn value -> __MODULE__.apply_mapper(^mapper, value) end,
      name: entry.name,
      inputs: entry.inputs,
      outputs: entry.outputs
    )
  end

  def to_runic!(%{type: :reduce} = entry) do
    reducer = entry.reducer

    Runic.reduce(
      entry.init,
      fn value, acc -> __MODULE__.apply_reducer(^reducer, value, acc) end,
      name: entry.name,
      map: entry.map,
      inputs: entry.inputs,
      outputs: entry.outputs
    )
  end

  def to_runic!(%{type: :accumulate} = entry) do
    reducer = entry.reducer

    Runic.accumulator(
      entry.init,
      fn value, state -> __MODULE__.apply_reducer(^reducer, value, state) end,
      name: entry.name,
      inputs: entry.inputs,
      outputs: entry.outputs
    )
  end

  @doc false
  def apply_mapper(mapper, value), do: apply_callable(mapper, [value])

  @doc false
  def apply_reducer(reducer, value, acc), do: apply_callable(reducer, [value, acc])

  defp apply_callable({module, function}, args), do: apply(module, function, args)
  defp apply_callable({:mfa, module, function}, args), do: apply(module, function, args)
end
