defmodule Jido.Flow.DSL.SourceMap do
  @moduledoc false

  @doc false
  @spec from_module(module(), String.t() | nil) :: Jido.Flow.source_map()
  def from_module(module, default_file \\ nil) do
    module |> Spark.Dsl.Extension.get_entities([:flow]) |> from_entities(default_file)
  end

  @doc false
  @spec from_entities(list(), String.t() | nil) :: Jido.Flow.source_map()
  def from_entities(entities, default_file \\ nil) do
    entities
    |> Enum.reduce(%{}, &put_source/2)
    |> Map.new(fn {path, location} ->
      location =
        if is_binary(default_file), do: Map.put_new(location, :file, default_file), else: location

      {path, location}
    end)
  end

  @doc false
  @spec lookup(Jido.Flow.source_map(), map()) :: map() | nil
  def lookup(source_map, details) do
    paths =
      case details do
        %{path: [_ | _] = path} ->
          [path]

        %{component: component, field: :fallback} ->
          [[:components, component, :fallback], [:components, component]]

        %{component: component, field: field} when is_binary(field) ->
          [[:components, component, :options, field], [:components, component]]

        %{component: component} ->
          [[:components, component]]

        _ ->
          []
      end

    Enum.find_value(paths, fn path ->
      Enum.find_value(length(path)..0//-1, &Map.get(source_map, Enum.take(path, &1)))
    end)
  end

  alias Jido.Flow.DSL.{Choice, Iterate, Output}

  @doc false
  @spec attach_issue(Jido.Flow.Definition.issue(), list()) :: Exception.t()
  def attach_issue(%{error: error, location: location}, entities) do
    entity =
      case location do
        [:output | _rest] ->
          Enum.find(entities, &match?(%Output{}, &1))

        [:components, index, :options, option_index | _rest]
        when is_integer(index) and is_integer(option_index) ->
          entities
          |> Enum.reject(&match?(%Output{}, &1))
          |> Enum.at(index)
          |> Map.get(:options, [])
          |> Enum.at(option_index)

        [:components, index, :fallback | _rest] when is_integer(index) ->
          entities
          |> Enum.reject(&match?(%Output{}, &1))
          |> Enum.at(index)
          |> Map.get(:fallback)

        [:components, index, :state, :update | _rest] when is_integer(index) ->
          entities |> Enum.reject(&match?(%Output{}, &1)) |> Enum.at(index)

        [:components, index, :state | _rest] when is_integer(index) ->
          entities
          |> Enum.reject(&match?(%Output{}, &1))
          |> Enum.at(index)
          |> Map.get(:state)

        [:components, index | _rest] when is_integer(index) ->
          entities |> Enum.reject(&match?(%Output{}, &1)) |> Enum.at(index)

        [:components] ->
          Enum.find(entities, &(Map.get(&1, :name) in error.details.components))

        _other ->
          nil
      end

    if entity, do: attach_entity(error, entity), else: error
  end

  @doc false
  @spec attach_entity(Exception.t(), term()) :: Exception.t()
  def attach_entity(%{details: details} = error, entity) when is_map(details) do
    %{error | details: Map.merge(entity_source(entity), details)}
  end

  def attach_entity(error, _entity), do: error

  defp annotation_map(nil), do: %{}

  defp annotation_map(anno) do
    %{}
    |> maybe_put(:line, :erl_anno.line(anno))
    |> maybe_put(:column, :erl_anno.column(anno))
  end

  defp maybe_put(map, _key, :undefined), do: map
  defp maybe_put(map, _key, 0), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp put_source(%Output{} = output, source_map) do
    Map.put(source_map, [:output], entity_source(output))
  end

  defp put_source(%Choice{} = choice, source_map) do
    source_map
    |> Map.put([:components, choice.name], entity_source(choice))
    |> put_choice_sources(choice)
  end

  defp put_source(%Iterate{} = iterate, source_map) do
    source_map
    |> Map.put([:components, iterate.name], entity_source(iterate))
    |> maybe_put_source([:components, iterate.name, :state], iterate.state)
  end

  defp put_source(entity, source_map) do
    Map.put(source_map, [:components, Map.fetch!(entity, :name)], entity_source(entity))
  end

  defp put_choice_sources(source_map, choice) do
    source_map =
      Enum.reduce(choice.options, source_map, fn option, current ->
        Map.put(
          current,
          [:components, choice.name, :options, option.name],
          entity_source(option)
        )
      end)

    maybe_put_source(
      source_map,
      [:components, choice.name, :fallback],
      choice.fallback
    )
  end

  defp maybe_put_source(source_map, _path, nil), do: source_map

  defp maybe_put_source(source_map, path, entity),
    do: Map.put(source_map, path, entity_source(entity))

  defp entity_source(entity) do
    entity
    |> Spark.Dsl.Entity.anno()
    |> annotation_map()
    |> Map.merge(Map.get(entity, :__source__, %{}))
  end
end
