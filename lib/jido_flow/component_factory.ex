defmodule Jido.Flow.ComponentFactory do
  @moduledoc false

  require Runic

  alias Jido.Flow.{Step, Switch}

  @doc false
  def to_runic!(%{type: :step} = entry) do
    Step.new(entry.action, entry.params, name: entry.name, context: entry.context)
  end

  def to_runic!(%{type: :project} = entry) do
    path = entry.path

    Runic.step(
      fn value -> __MODULE__.apply_project(^path, value) end,
      name: entry.name
    )
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

  def to_runic!(%{type: :collect} = entry) do
    arguments = entry.arguments

    Runic.step(
      fn value -> __MODULE__.apply_collect(^arguments, value) end,
      name: entry.name
    )
  end

  def to_runic!(%{type: type} = entry) when type in [:debug, :trace] do
    Runic.step(
      fn value -> value end,
      name: entry.name
    )
  end

  def to_runic!(%{type: :switch} = entry), do: Switch.new(entry)

  @doc false
  def apply_mapper(mapper, value), do: apply_callable(mapper, [value])

  @doc false
  def apply_reducer(reducer, value, acc), do: apply_callable(reducer, [value, acc])

  @doc false
  def apply_project(path, value) do
    case fetch_path(value, path) do
      {:ok, selected} ->
        selected

      :error ->
        raise ArgumentError, "project path #{inspect(path)} not found"
    end
  end

  @doc false
  def apply_collect(arguments, value) do
    values =
      case value do
        values when is_list(values) -> values
        value -> [value]
      end

    argument_keys = Map.keys(arguments)

    argument_keys
    |> Enum.zip(values)
    |> Map.new()
  end

  defp apply_callable({module, function}, args), do: apply(module, function, args)
  defp apply_callable({:mfa, module, function}, args), do: apply(module, function, args)

  defp fetch_path(value, []), do: {:ok, value}

  defp fetch_path(%{} = value, [key | rest]) when is_atom(key) do
    case Map.fetch(value, key) do
      {:ok, next} -> fetch_path(next, rest)
      :error -> :error
    end
  end

  defp fetch_path(value, [index | rest]) when is_list(value) and is_integer(index) do
    case Enum.fetch(value, index) do
      {:ok, next} -> fetch_path(next, rest)
      :error -> :error
    end
  end

  defp fetch_path(_value, _path), do: :error
end
